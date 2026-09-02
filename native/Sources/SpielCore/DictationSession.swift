import Foundation
import FluidAudio

/// Drives one dictation: mic -> VAD -> segment -> transcribe -> assemble -> glossary.
///
/// Three structural fixes over the Electron version live here.
///
/// 1. **VAD is not tied to the render loop.** v1 ran silence detection inside a
///    `requestAnimationFrame` callback at ~60 Hz, which burned CPU (each tick also
///    fired a React `setState` re-rendering the whole window) and coupled speech
///    detection to the compositor — if the window were throttled, silence detection
///    would stop with it. Here VAD runs on the audio path; the UI is a separate,
///    throttled observer.
///
/// 2. **Segments keep their order.** Each segment is stamped with a monotonically
///    increasing index at CAPTURE time and reassembled by `TranscriptAssembler`, so a
///    slow segment can no longer land after a fast one and swap two sentences.
///
/// 3. **Audio reaches the VAD in whole frames, in order.** See `vadFrameSamples` and
///    `AudioSink` — both are load-bearing and both fix bugs that only bite on the live
///    microphone path.
public actor DictationSession {

    /// Silero's native frame. `VadManager.chunkSize` is 4096 samples (256 ms at
    /// 16 kHz) and `processChunk` **pads anything shorter by repeating the last
    /// sample**.
    ///
    /// This matters enormously and is easy to get wrong: `AVAudioEngine` taps at 1024
    /// frames of the *device* rate, which after conversion to 16 kHz is only ~341
    /// samples. Forwarding tap buffers straight to the VAD therefore fed Silero ~8%
    /// real audio and ~92% constant fill, ~45 times a second instead of ~4 — so every
    /// speech/silence probability was computed on mostly-synthetic input. The session
    /// now accumulates to exactly this many samples before each VAD call, and derives
    /// its speech/silence timers from the frame length rather than from tap sizes.
    public static let vadFrameSamples = 4096
    public static let vadFrameSeconds = Double(vadFrameSamples) / AudioCapture.sampleRate

    public struct Config: Sendable {
        /// Silence needed to close a segment. Rounded up to whole VAD frames.
        public var silenceDuration: TimeInterval = 0.7
        /// Reject blips shorter than this.
        public var minSpeechDuration: TimeInterval = 0.3
        /// Speech probability above which Silero says "voice".
        public var speechThreshold: Float = 0.5
        /// Prepended to each segment so the leading consonant is never clipped.
        /// v1 cleared its chunk buffer at the instant speech was detected, discarding
        /// the audio containing the start of the word.
        public var preRoll: TimeInterval = 0.3
        /// Hard ceiling on one segment, so a monologue still streams.
        public var maxSegmentDuration: TimeInterval = 20.0
        public init() {}
    }

    public enum Event: Sendable {
        case speechStarted
        case segmentCaptured(index: Int, seconds: Double)
        case textReleased(String)
        case error(String)
    }

    private let config: Config
    private let transcriber: any Transcriber
    private let glossary: Glossary
    private let assembler = TranscriptAssembler()

    /// Nonisolated so the audio thread can push into it without a Task or an actor hop.
    public nonisolated let sink = AudioSink()
    private var consumer: Task<Void, Never>?

    private var vad: VadManager?
    private var vadState: VadStreamState?

    /// Samples received but not yet forming a whole VAD frame.
    private var pending: [Float] = []
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
        // Silero VAD — a real model, not the amplitude threshold v1 used. An amplitude
        // gate fires on a door slam and misses a quiet sentence.
        vad = try await VadManager()
        vadState = await vad?.makeStreamState()
        startConsumer()
    }

    /// Exactly ONE consumer drains the sink, sequentially. Nothing else calls
    /// `processFrame`, so a VAD `await` can never interleave two frames and read a
    /// stale `vadState` or append samples out of capture order.
    private func startConsumer() {
        guard consumer == nil else { return }
        let stream = sink.stream
        consumer = Task { [weak self] in
            for await chunk in stream {
                await self?.ingest(chunk)
            }
        }
    }

    public func setEventHandler(_ handler: @escaping @Sendable (Event) -> Void) {
        eventHandler = handler
    }

    public func reset() async {
        for t in inFlight { t.cancel() }
        inFlight.removeAll()
        await assembler.reset()
        pending.removeAll()
        preRollBuffer.removeAll()
        current.removeAll()
        speaking = false
        silenceRun = 0
        speechRun = 0
        nextIndex = 0
        vadState = await vad?.makeStreamState()
        if let p = transcriber as? ParakeetTranscriber { await p.resetContext() }
    }

    /// Accumulate into whole Silero frames, then process them one at a time.
    private func ingest(_ samples: [Float]) async {
        pending.append(contentsOf: samples)
        while pending.count >= Self.vadFrameSamples {
            let frame = Array(pending.prefix(Self.vadFrameSamples))
            pending.removeFirst(Self.vadFrameSamples)
            await processFrame(frame)
        }
    }

    private func processFrame(_ frame: [Float]) async {
        guard let vad, let state = vadState else { return }

        var probability: Float = 0
        do {
            let result = try await vad.processStreamingChunk(
                frame, state: state, config: .default,
                returnSeconds: false, timeResolution: 2
            )
            vadState = result.state
            probability = result.probability
        } catch {
            // A VAD failure must not kill dictation. Treat the audio as speech —
            // over-capturing is recoverable, dropping the user's words is not.
            probability = 1.0
        }

        let isSpeech = probability >= config.speechThreshold
        let seconds = Self.vadFrameSeconds

        if isSpeech {
            if !speaking {
                speaking = true
                speechRun = 0
                // Start the segment with the pre-roll so the word's onset survives.
                current = preRollBuffer
                preRollBuffer.removeAll()
                eventHandler?(.speechStarted)
            }
            current.append(contentsOf: frame)
            speechRun += seconds
            silenceRun = 0
            if speechRun >= config.maxSegmentDuration {
                await closeSegment()
            }
        } else if speaking {
            current.append(contentsOf: frame)  // keep trailing silence for context
            silenceRun += seconds
            if silenceRun >= config.silenceDuration {
                await closeSegment()
            }
        } else {
            // Rolling pre-roll window while idle.
            preRollBuffer.append(contentsOf: frame)
            let maxPre = Int(config.preRoll * AudioCapture.sampleRate)
            if preRollBuffer.count > maxPre {
                preRollBuffer.removeFirst(preRollBuffer.count - maxPre)
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
        eventHandler?(.segmentCaptured(
            index: index, seconds: Double(audio.count) / AudioCapture.sampleRate
        ))

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
                // Emit an empty segment so the assembler's ordering gate does not stall
                // on a hole and swallow everything spoken after it.
                _ = await assembler.accept(
                    TranscriptSegment(index: index, text: "", isFinal: true)
                )
                eventHandler?(.error("segment \(index): \(error)"))
            }
        }
        inFlight.append(task)
    }

    /// Ends dictation and returns the finished, glossary-corrected transcript.
    ///
    /// Order matters: close the sink, drain the consumer, THEN flush the tail — so
    /// audio still queued in the stream is not thrown away.
    public func finish() async -> String {
        sink.finish()
        await consumer?.value
        consumer = nil

        // Whatever is left below one VAD frame is still real speech.
        if !pending.isEmpty {
            if speaking {
                current.append(contentsOf: pending)
            } else if pending.count > Int(config.minSpeechDuration * AudioCapture.sampleRate) {
                current = preRollBuffer + pending
                speaking = true
                speechRun = max(speechRun, config.minSpeechDuration)
            }
            pending.removeAll()
        }
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
