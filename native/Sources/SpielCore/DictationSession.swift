import Foundation
import FluidAudio

/// Drives one dictation: mic -> VAD -> segment -> transcribe -> assemble -> glossary.
///
/// Two structural fixes over the Electron version live here.
///
/// 1. **VAD is not tied to the render loop.** The old app ran silence detection inside
///    a `requestAnimationFrame` callback at ~60 Hz, which both burned CPU (each tick
///    also fired a React `setState` that re-rendered the whole window) and coupled
///    speech detection to the compositor -- if the window were ever throttled, silence
///    detection would stop with it. Here VAD runs on the audio path and the UI is a
///    separate, throttled observer.
///
/// 2. **Segments keep their order.** Each segment is stamped with a monotonically
///    increasing index at CAPTURE time and reassembled by `TranscriptAssembler`, so a
///    slow segment can no longer land after a fast one and swap two sentences.
public actor DictationSession {

    public struct Config: Sendable {
        /// Silence needed to close a segment.
        public var silenceDuration: TimeInterval = 0.7
        /// Reject blips shorter than this.
        public var minSpeechDuration: TimeInterval = 0.3
        /// Speech probability above which Silero says "voice".
        public var speechThreshold: Float = 0.5
        /// Prepended to each segment so the leading consonant is never clipped.
        /// The Electron VAD cleared its chunk buffer at the instant speech was
        /// detected, discarding the chunk that contained the start of the word.
        public var preRoll: TimeInterval = 0.3
        /// Hard ceiling on one segment, so a monologue still streams.
        public var maxSegmentDuration: TimeInterval = 20.0
        public init() {}
    }

    public enum Event: Sendable {
        case levels([Float])
        case speechStarted
        case segmentCaptured(index: Int, seconds: Double)
        case textReleased(String)
        case error(String)
    }

    private let config: Config
    private let transcriber: any Transcriber
    private let glossary: Glossary
    private let assembler = TranscriptAssembler()

    private var vad: VadManager?
    private var vadState: VadStreamState?

    private var preRollBuffer: [Float] = []
    private var current: [Float] = []
    private var speaking = false
    private var silenceRun: TimeInterval = 0
    private var speechRun: TimeInterval = 0
    private var nextIndex = 0
    private var inFlight: [Task<Void, Never>] = []
    private var eventHandler: (@Sendable (Event) -> Void)?

    public init(
        transcriber: any Transcriber,
        glossary: Glossary = Glossary(),
        config: Config = Config()
    ) {
        self.transcriber = transcriber
        self.glossary = glossary
        self.config = config
    }

    public func prepare() async throws {
        try await transcriber.prepare()
        // Silero VAD -- a real model, not the amplitude threshold the old app used.
        // An amplitude gate fires on a door slam and misses a quiet sentence.
        vad = try await VadManager()
        vadState = await vad?.makeStreamState()
    }

    public func setEventHandler(_ handler: @escaping @Sendable (Event) -> Void) {
        eventHandler = handler
    }

    public func reset() async {
        for t in inFlight { t.cancel() }
        inFlight.removeAll()
        await assembler.reset()
        preRollBuffer.removeAll()
        current.removeAll()
        speaking = false
        silenceRun = 0
        speechRun = 0
        nextIndex = 0
        vadState = await vad?.makeStreamState()
        if let p = transcriber as? ParakeetTranscriber { await p.resetContext() }
    }

    /// Feed 16 kHz mono samples from the mic.
    public func feed(_ samples: [Float]) async {
        guard let vad, var state = vadState else { return }
        let seconds = Double(samples.count) / AudioCapture.sampleRate

        var probability: Float = 0
        do {
            let result = try await vad.processStreamingChunk(
                samples, state: state, config: .default,
                returnSeconds: false, timeResolution: 2
            )
            state = result.state
            vadState = state
            probability = result.probability
        } catch {
            // A VAD failure must not kill dictation. Fall through treating the audio
            // as speech -- over-capturing is recoverable, dropping the user's words
            // is not.
            probability = 1.0
        }

        let isSpeech = probability >= config.speechThreshold

        if isSpeech {
            if !speaking {
                speaking = true
                speechRun = 0
                // Start the segment with the pre-roll so the word's onset survives.
                current = preRollBuffer
                eventHandler?(.speechStarted)
            }
            current.append(contentsOf: samples)
            speechRun += seconds
            silenceRun = 0
            if speechRun >= config.maxSegmentDuration {
                await closeSegment()
            }
        } else {
            if speaking {
                current.append(contentsOf: samples)  // keep trailing silence for context
                silenceRun += seconds
                if silenceRun >= config.silenceDuration {
                    await closeSegment()
                }
            } else {
                // Maintain a rolling pre-roll window while idle.
                preRollBuffer.append(contentsOf: samples)
                let maxPre = Int(config.preRoll * AudioCapture.sampleRate)
                if preRollBuffer.count > maxPre {
                    preRollBuffer.removeFirst(preRollBuffer.count - maxPre)
                }
            }
        }
    }

    private func closeSegment() async {
        let audio = current
        current.removeAll()
        preRollBuffer.removeAll()
        speaking = false
        let spoke = speechRun
        speechRun = 0
        silenceRun = 0

        guard spoke >= config.minSpeechDuration, !audio.isEmpty else { return }

        let index = nextIndex
        nextIndex += 1
        eventHandler?(.segmentCaptured(index: index, seconds: Double(audio.count) / AudioCapture.sampleRate))

        let task = Task { [transcriber, assembler, glossary, eventHandler] in
            do {
                let raw = try await transcriber.transcribe(samples: audio)
                let released = await assembler.accept(
                    TranscriptSegment(index: index, text: raw, isFinal: true)
                )
                if !released.isEmpty {
                    eventHandler?(.textReleased(glossary.apply(to: released)))
                }
            } catch {
                // Emit an empty segment so the assembler's ordering gate does not
                // stall forever on a hole and swallow everything spoken after it.
                _ = await assembler.accept(
                    TranscriptSegment(index: index, text: "", isFinal: true)
                )
                eventHandler?(.error("segment \(index): \(error)"))
            }
        }
        inFlight.append(task)
    }

    /// Ends dictation and returns the finished, glossary-corrected transcript.
    public func finish() async -> String {
        if speaking || !current.isEmpty {
            speechRun = max(speechRun, config.minSpeechDuration)
            await closeSegment()
        }
        for t in inFlight { _ = await t.value }
        inFlight.removeAll()
        _ = await assembler.flush()
        let text = await assembler.text()
        return glossary.apply(to: text)
    }

    /// One-shot: transcribe a fixed buffer with no VAD. Used by the CLI for
    /// file-based verification.
    public func transcribeWhole(_ samples: [Float]) async throws -> String {
        let raw = try await transcriber.transcribe(samples: samples)
        return glossary.apply(to: raw)
    }
}
