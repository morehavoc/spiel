import Foundation

/// Append-only log at ~/Library/Logs/Spiel.log.
///
/// A menu-bar app has no console. When the first test build "basically wasn't
/// working", there was nothing to read: every outcome was a Notifier call that
/// silently degraded to NSLog when notification permission had never been requested.
/// This file is the thing to paste into the thread when something looks wrong.
public enum DiagnosticLog {
    public static let url: URL = {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("Spiel.log")
    }()

    private static let queue = DispatchQueue(label: "com.morehavoc.spiel.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public static func write(_ line: String) {
        let text = "[\(stamp.string(from: Date()))] \(line)\n"
        queue.async {
            guard let data = text.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
        NSLog("Spiel: %@", line)
    }
}
