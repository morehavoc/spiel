import Foundation
import FluidAudio

/// NVIDIA Parakeet Unified EN 0.6B via FluidAudio's batch path — the default engine
/// since 2.2.0 (2026-09-23).
///
/// Chosen on Christopher's own voice, not a vendor table: five clips (a walking
/// video, a short, two conference-talk clips and six minutes of a talk; 1,899 words
/// against hand-corrected captions) through the real dictation pipeline scored
/// aggregate WER 6.7 % for this model vs 11.2 % for TDT v3, 8.5 % for TDT v2 and
/// 10.4 % for Apple's SpeechAnalyzer. v3 (multilingual) also returned an EMPTY
/// transcript for one whole 13 s segment of the talk — a dropped chunk the
/// assembler cannot see. Same parameter count as v3; English-only, punctuated.
///
/// No decoder state is carried between calls (the batch path has none), so
/// `resetContext()` is the protocol's no-op default.
public actor ParakeetUnifiedTranscriber: Transcriber {
    public nonisolated let kind: TranscriberKind = .parakeet
    private var manager: UnifiedAsrManager?

    public init() {}

    public func prepare() async throws {
        if manager != nil { return }
        do {
            let m = UnifiedAsrManager()
            try await m.loadModels()
            manager = m
        } catch {
            throw TranscriberError.unavailable("Parakeet Unified model load failed: \(error)")
        }
    }

    public func transcribe(samples: [Float]) async throws -> String {
        guard let manager else { throw TranscriberError.notPrepared("call prepare() first") }
        guard !samples.isEmpty else { return "" }
        // Same floor as ParakeetTranscriber: a STOP-closed segment can be one
        // 4,096-sample VAD frame; pad with silence rather than risk a short-input throw.
        let floor = Int(AudioCapture.sampleRate * 0.5)
        let input = samples.count >= floor
            ? samples
            : samples + [Float](repeating: 0, count: floor - samples.count)
        do {
            return try await manager.transcribe(input).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw TranscriberError.failed("\(error)")
        }
    }
}
