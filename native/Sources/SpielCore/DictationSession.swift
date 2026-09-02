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

    /// What one dictation actually did — so an empty transcript can be told apart
    /// from "the microphone delivered silence", "audio arrived but nothing was
    /// judged speech", and "speech was transcribed to nothing". Those are three
    /// different problems with three different fixes, and the first build reported
    /// all of them as a blank.
    public struct Report: Sendable {
        public var text: String = ""
        /// Audio that reached the session, in seconds at 16 kHz.
        public var audioSeconds: Double = 0
        /// Largest absolute sample seen. ~0 means the mic (or its permission) gave us nothing.
        public var peak: Float = 0
        /// Number of segments the VAD closed and handed to the engine.
        public var segments: Int = 0
        /// Buffers the audio thread submitted while no stream was armed. Must be 0.
        public var droppedBuffers: Int = 0
        public var errors: [String] = []

        public init() {}

        /// One-line human diagnosis. Written for the menu bar, where this is the
        /// only thing the user will see when nothing was inserted.
        public var diagnosis: String {
            let secs = String(format: "%.1fs", audioSeconds)
            // Problems first, always — a non-empty transcript must not hide that part
            // of the audio was dropped or part of the speech failed to transcribe.
            var warnings: [String] = []
            if droppedBuffers > 0 {
                warnings.append("BUG: \(droppedBuffers) audio buffer\(droppedBuffers == 1 ? "" : "s") dropped before reaching the session")
            }
            if !errors.isEmpty {
                warnings.append("\(errors.count) segment\(errors.count == 1 ? "" : "s") failed: \(errors.joined(separator: "; "))")
            }
            if !text.isEmpty {
                let summary = "\(secs), \(segments) segment\(segments == 1 ? "" : "s"), \(text.split(separator: " ").count) words"
                return warnings.isEmpty ? summary : "PARTIAL — " + warnings.joined(separator: "; ") + " — " + summary
            }
            if droppedBuffers > 0 && audioSeconds == 0 {
                return warnings[0]
            }
            if audioSeconds == 0 {
                return "no audio reached the session — the microphone delivered nothing"
            }
            if peak < 0.005 {
                return "\(secs) of near-silence (peak \(String(format: "%.4f", peak))) — the mic is muted, the wrong input device is selected, or microphone permission is missing"
            }
            if segments == 0 {
                return "\(secs) of audio (peak \(String(format: "%.2f", peak))) but no speech detected — too quiet, or too short"
            }
            if !errors.isEmpty {
                return "\(segments) segment\(segments == 1 ? "" : "s") captured, engine failed: \(errors.joined(separator: "; "))"
            }
            return "\(segments) segment\(segments == 1 ? "" : "s") captured (peak \(String(format: "%.2f", peak))) but the engine returned no words"
        }
    }

    private let config: Config
    private let transcriber: any Transcriber
    private var glossary: Glossary
    private let assembler = TranscriptAssembler()

    /// Nonisolated so the audio thread can push into it without a Task or an actor hop.
    public nonisolated let sink = AudioSink()
    private var consumer: Task<Void, Never>?

    private var vad: (any VoiceActivityDetector)?
    private let injectedVAD: (any VoiceActivityDetector)?

    /// The in-flight `finishWithReport()`, so a `reset()` that arrives while it is
    /// suspended (a fast second hotkey press) waits for it instead of interleaving —
    /// actors are reentrant, and a reset that re-armed mid-finish would then have its
    /// consumer nil'd by the older finish resuming.
    private var finishInFlight: Task<Report, Never>?

    private var receivedSamples = 0
    private var peak: Float = 0
    private var segmentsClosed = 0
    private var errors: [String] = []

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

    /// `vad` is injectable so the whole pipeline can run under `selftest` with a
    /// deterministic detector. Production passes nil and gets Silero.
    public init(
        transcriber: any Transcriber,
        glossary: Glossary = Glossary(),
        config: Config = Config(),
        vad: (any VoiceActivityDetector)? = nil
    ) {
        self.transcriber = transcriber
        self.glossary = glossary
        self.config = config
        self.injectedVAD = vad
    }

    public func prepare() async throws {
        try await transcriber.prepare()
        // Silero VAD — a real model, not the amplitude threshold v1 used. An amplitude
        // gate fires on a door slam and misses a quiet sentence.
        if let injectedVAD {
            vad = injectedVAD
        } else {
            vad = try await SileroVAD()
        }
        armForDictation()
    }

    /// True while a consumer is draining an armed stream — i.e. audio submitted now
    /// will actually be processed.
    public var isArmed: Bool { consumer != nil && sink.isArmed }

    /// Arms a fresh stream and exactly ONE consumer to drain it, sequentially.
    /// Nothing else calls `processFrame`, so a VAD `await` can never interleave two
    /// frames and read stale VAD state or append samples out of capture order.
    ///
    /// Called from `prepare()` and again from every `reset()` — the stream is
    /// one-shot (see `AudioSink`), so a session that only armed once went deaf after
    /// its first `finish()`.
    private func armForDictation() {
        let stream = sink.rearm()
        consumer = Task { [weak self] in
            for await chunk in stream {
                await self?.ingest(chunk)
            }
        }
    }

    /// Swap the vocabulary (re-read from the user file at each start).
    public func setGlossary(_ g: Glossary) { glossary = g }

    public func setEventHandler(_ handler: @escaping @Sendable (Event) -> Void) {
        eventHandler = handler
    }

    /// Start of a dictation. Clears every per-dictation state AND re-arms the audio
    /// path — a session is reusable across dictations only because this re-arms.
    public func reset() async {
        // 1. Let a finish that is still running complete — never interleave with it.
        if let f = finishInFlight { _ = await f.value }
        // 2. Drain whatever the OLD consumer still had queued BEFORE clearing state,
        //    so stale audio cannot be ingested into the new dictation's counters.
        if consumer != nil { sink.finish(); await consumer?.value; consumer = nil }
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
        receivedSamples = 0
        peak = 0
        segmentsClosed = 0
        errors.removeAll()
        await vad?.reset()
        if let p = transcriber as? ParakeetTranscriber { await p.resetContext() }
        // 3. Only now arm a fresh stream.
        armForDictation()
    }

    /// Accumulate into whole Silero frames, then process them one at a time.
    private func ingest(_ samples: [Float]) async {
        receivedSamples += samples.count
        for s in samples { let a = abs(s); if a > peak { peak = a } }
        pending.append(contentsOf: samples)
        while pending.count >= Self.vadFrameSamples {
            let frame = Array(pending.prefix(Self.vadFrameSamples))
            pending.removeFirst(Self.vadFrameSamples)
            await processFrame(frame)
        }
    }

    private func processFrame(_ frame: [Float]) async {
        guard let vad else { return }

        var probability: Float = 0
        do {
            probability = try await vad.probability(of: frame)
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
        segmentsClosed += 1
        eventHandler?(.segmentCaptured(
            index: index, seconds: Double(audio.count) / AudioCapture.sampleRate
        ))

        let task = Task { [weak self, transcriber, assembler, glossary, eventHandler] in
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
                await self?.recordError("segment \(index): \(error)")
                eventHandler?(.error("segment \(index): \(error)"))
            }
        }
        inFlight.append(task)
    }

    private func recordError(_ e: String) { errors.append(e) }

    /// Ends dictation and returns the finished, glossary-corrected transcript.
    public func finish() async -> String {
        await finishWithReport().text
    }

    /// Ends dictation and returns the transcript plus what happened on the way.
    ///
    /// Order matters: close the sink, drain the consumer, THEN flush the tail — so
    /// audio still queued in the stream is not thrown away. After this the session
    /// is DISARMED until the next `reset()`; submits in between are counted, not lost.
    public func finishWithReport() async -> Report {
        if let f = finishInFlight { return await f.value }
        let task = Task { await self.finishBody() }
        finishInFlight = task
        let report = await task.value
        finishInFlight = nil
        return report
    }

    private func finishBody() async -> Report {
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

        var report = Report()
        report.text = glossary.apply(to: text)
        report.audioSeconds = Double(receivedSamples) / AudioCapture.sampleRate
        report.peak = peak
        report.segments = segmentsClosed
        report.droppedBuffers = sink.droppedBuffers
        report.errors = errors
        return report
    }

    /// One-shot: transcribe a fixed buffer with no VAD. Used by the CLI for
    /// file-based verification.
    public func transcribeWhole(_ samples: [Float]) async throws -> String {
        let raw = try await transcriber.transcribe(samples: samples)
        return glossary.apply(to: raw)
    }
}
