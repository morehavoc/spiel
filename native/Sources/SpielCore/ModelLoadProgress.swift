import Foundation
import FluidAudio

/// Where a speech-model load is, in terms a progress bar can show honestly.
///
/// FluidAudio reports one fraction for the whole load, but its repo loads give the
/// DOWNLOAD phase the first half of it (`downloadPhaseWeight: 0.5` in
/// `ModelHub.download`, 0.15.6) and CoreML compilation the second — and the
/// compile of a model that `loadWithRecovery` loads happens inside a closure that
/// gets no progress handler at all, so the raw fraction parks at 0.5 for the whole
/// compile. Shown raw, that is a bar stuck at 50 % while the Neural Engine works.
/// So the bar tracks the download alone (fraction ÷ weight: bytes when the file
/// sizes are known, file counts otherwise — FluidAudio's own measure, not ours),
/// and compiling is a separate, indeterminate phase.
public struct ModelLoadProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case listing
        case downloading(completedFiles: Int, totalFiles: Int)
        case compiling
    }
    public let phase: Phase
    /// 0...1 of the download, while downloading; nil otherwise (no number to show).
    public let downloadFraction: Double?

    /// FluidAudio 0.15.6 `ModelHub.download`: "Repo loads: download occupies 0-0.5".
    public static let downloadPhaseWeight = 0.5

    public init(phase: Phase, rawFraction: Double) {
        self.phase = phase
        if case .downloading = phase {
            downloadFraction = min(max(rawFraction / Self.downloadPhaseWeight, 0), 1)
        } else {
            downloadFraction = nil
        }
    }

    static func from(_ p: DownloadProgress) -> ModelLoadProgress {
        switch p.phase {
        case .listing: return ModelLoadProgress(phase: .listing, rawFraction: p.fractionCompleted)
        case .downloading(let done, let total):
            return ModelLoadProgress(phase: .downloading(completedFiles: done, totalFiles: total), rawFraction: p.fractionCompleted)
        case .compiling: return ModelLoadProgress(phase: .compiling, rawFraction: p.fractionCompleted)
        }
    }

    /// FluidAudio's handler type, wrapping ours; nil in, nil out.
    static func handler(_ h: ModelProgressHandler?) -> ProgressHandler? {
        guard let h else { return nil }
        return { h(ModelLoadProgress.from($0)) }
    }
}

/// Called on an unspecified queue — hop to the main actor before touching UI.
public typealias ModelProgressHandler = @Sendable (ModelLoadProgress) -> Void
