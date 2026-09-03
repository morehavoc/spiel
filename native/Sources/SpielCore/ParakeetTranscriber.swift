import AVFoundation
import Foundation
import FluidAudio

/// NVIDIA Parakeet TDT running on the Apple Neural Engine via FluidAudio (Apache 2.0).
///
/// This is the primary engine. On Argmax's M4 Mac mini benchmark, Parakeet-v2 measured
/// 11.7% WER at a 359x speed factor -- the only engine in that comparison that beats
/// Apple's SpeechTranscriber (14.0% / 70x) on accuracy AND speed simultaneously.
/// FluidAudio's own published figure is ~190x realtime on an M4 Pro.
///
/// Model weights are downloaded from HuggingFace on first run (hundreds of MB) and
/// cached by FluidAudio. They are never committed to this repo.
public actor ParakeetTranscriber: Transcriber {
    public nonisolated let kind: TranscriberKind = .parakeet

    private let version: AsrModelVersion
    private var manager: AsrManager?
    private var decoderState: TdtDecoderState?

    public init(version: AsrModelVersion = .v3) {
        self.version = version
    }

    public func prepare() async throws {
        if manager != nil { return }
        do {
            let models = try await AsrModels.downloadAndLoad(version: version)
            let mgr = AsrManager(config: .default)
            try await mgr.loadModels(models)
            self.manager = mgr
            self.decoderState = try TdtDecoderState()
        } catch {
            throw TranscriberError.unavailable("Parakeet model load failed: \(error)")
        }
    }

    public func transcribe(samples: [Float]) async throws -> String {
        guard let manager else { throw TranscriberError.notPrepared("call prepare() first") }
        guard !samples.isEmpty else { return "" }

        // FluidAudio throws `invalidAudioData` below `ASRConstants.minimumRequiredSamples`
        // (0.3 s = 4,800 samples). A segment closed by the STOP hotkey can be a single
        // 4,096-sample VAD frame with no pre-roll yet, which would turn "yes" into a
        // reported engine failure. Pad with silence to the floor; the model is trained
        // on padded windows anyway.
        let floor = ASRConstants.minimumRequiredSamples(forSampleRate: Int(AudioCapture.sampleRate))
        let input = samples.count >= floor
            ? samples
            : samples + [Float](repeating: 0, count: floor - samples.count)

        // Parakeet is a transducer with carry-over decoder state. Reusing the state
        // across segments of one dictation preserves linguistic context at segment
        // boundaries -- the thing the old chunked-Whisper pipeline could never do,
        // because every segment was an independent HTTP request.
        if decoderState == nil { decoderState = try TdtDecoderState() }
        var state = decoderState!
        do {
            let result = try await manager.transcribe(input, decoderState: &state)
            decoderState = state
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw TranscriberError.failed("\(error)")
        }
    }

    /// Callers must not overlap `transcribe` calls: the carried state is read at
    /// entry and written at exit, and `AsrManager` is a reentrant actor, so two
    /// concurrent calls would race on it. `DictationSession` serialises segments.
    ///
    /// Clears carried decoder context. Call between dictations so one session's
    /// last word cannot bias the next session's first.
    public func resetContext() {
        decoderState = try? TdtDecoderState()
    }
}
