import AVFoundation
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

/// Facts about each engine's model on disk, for the setup window and `spiel doctor`.
public enum SpeechModels {
    /// FluidAudio's cache folder for the engine; nil for Apple (the OS manages it).
    public static func folderName(_ e: EngineChoice) -> String? {
        switch e {
        case .unified: return "parakeet-unified-en-0.6b"
        case .v3: return "parakeet-tdt-0.6b-v3"
        case .apple: return nil
        }
    }

    public static func displayName(_ e: EngineChoice) -> String {
        switch e {
        case .unified: return "Parakeet Unified EN 0.6B"
        case .v3: return "Parakeet TDT v3 0.6B"
        case .apple: return "Apple SpeechAnalyzer"
        }
    }

    /// Size on disk once downloaded, measured on jaws-mini (2026-09-27): unified
    /// 614.1 MB, v3 483.3 MB — decimal MB, the unit ByteCountFormatter shows beside
    /// it (`du -h` says 586M/461M in MiB). A label ("about 615 MB"), never a
    /// progress total.
    public static func approximateMB(_ e: EngineChoice) -> Int? {
        switch e {
        case .unified: return 615
        case .v3: return 485
        case .apple: return nil
        }
    }

    public static func folder(_ e: EngineChoice, in root: URL = DiagnosticsBundle.modelsFolder) -> URL? {
        folderName(e).map { root.appendingPathComponent($0, isDirectory: true) }
    }

    /// Bytes under the engine's folder, partial downloads included (FluidAudio
    /// streams into `<file>.partial` beside the target). 0 when absent.
    public static func bytesOnDisk(_ e: EngineChoice, in root: URL = DiagnosticsBundle.modelsFolder) -> Int64 {
        guard let folder = folder(e, in: root),
              let en = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in en {
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Downloaded = the folder holds at least one compiled model and no partial
    /// file. Not a load test — the app's warm-up is that — only enough to decide
    /// whether a first-run window has a download still to do. Apple's model is the
    /// OS's business; it counts as present wherever SpeechAnalyzer exists.
    public static func isDownloaded(_ e: EngineChoice, in root: URL = DiagnosticsBundle.modelsFolder) -> Bool {
        guard let folder = folder(e, in: root) else { return AppleSpeechTranscriber.isAvailable }
        guard let en = FileManager.default.enumerator(atPath: folder.path) else { return false }
        var sawModel = false
        for case let rel as String in en {
            if rel.hasSuffix(".partial") { return false }
            if rel.hasSuffix(".mlmodelc") { sawModel = true }
        }
        return sawModel
    }
}

/// The first-run setup checklist, as data. The window draws it; `launchDecision`
/// decides whether the window opens by itself.
public struct SetupChecklist: Sendable, Equatable {
    public enum Notifications: Sendable, Equatable { case notDetermined, allowed, denied }

    public var microphone: AudioCapture.MicrophoneAuthorization
    public var accessibility: Bool
    public var notifications: Notifications
    public var modelOnDisk: Bool

    public init(microphone: AudioCapture.MicrophoneAuthorization, accessibility: Bool,
                notifications: Notifications, modelOnDisk: Bool) {
        self.microphone = microphone
        self.accessibility = accessibility
        self.notifications = notifications
        self.modelOnDisk = modelOnDisk
    }

    /// Steps that still need the user. Notifications count as done once ANSWERED:
    /// a user who said no has made a choice, and reopening a window on every launch
    /// over an optional permission is nagging. Denied microphone is not done — no
    /// dictation works without it.
    public var remaining: [String] {
        var out: [String] = []
        if microphone != .authorized { out.append("microphone") }
        if !accessibility { out.append("accessibility") }
        if notifications == .notDetermined { out.append("notifications") }
        if !modelOnDisk { out.append("speech model") }
        return out
    }

    public var isComplete: Bool { remaining.isEmpty }

    public enum LaunchDecision: Sendable, Equatable {
        /// Open the window; it asks for permissions itself (no system prompts at launch).
        case show
        /// Everything is already in place (an upgrade from 2.4): set the flag, do not
        /// open the window, run the old launch path.
        case markDone
        /// Setup was finished or dismissed before: the old launch path, nothing new.
        case skip
    }

    public static func launchDecision(completed: Bool, _ c: SetupChecklist) -> LaunchDecision {
        if completed { return .skip }
        return c.isComplete ? .markDone : .show
    }
}
