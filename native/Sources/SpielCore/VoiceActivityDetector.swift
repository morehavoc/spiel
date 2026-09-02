import Foundation
import FluidAudio

/// Speech-probability for one whole VAD frame.
///
/// This seam exists so the dictation pipeline can be exercised end to end in
/// `spiel-cli selftest` without a model download, a microphone, or a TCC prompt.
/// The bug that motivated it — the audio sink going dead after the first dictation —
/// lived entirely in session lifecycle code and was invisible to every test that
/// stopped at the pure logic layer.
public protocol VoiceActivityDetector: Sendable {
    /// `frame` is exactly `DictationSession.vadFrameSamples` samples at 16 kHz.
    func probability(of frame: [Float]) async throws -> Float
    /// Clear any sequential state so one dictation cannot bias the next.
    func reset() async
}

/// Silero VAD via FluidAudio — the production detector.
public actor SileroVAD: VoiceActivityDetector {
    private let manager: VadManager
    private var state: VadStreamState

    public init() async throws {
        manager = try await VadManager()
        state = await manager.makeStreamState()
    }

    public func probability(of frame: [Float]) async throws -> Float {
        let result = try await manager.processStreamingChunk(
            frame, state: state, config: .default, returnSeconds: false, timeResolution: 2
        )
        state = result.state
        return result.probability
    }

    public func reset() async {
        state = await manager.makeStreamState()
    }
}
