import AVFoundation
import Foundation
import FluidAudio

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
