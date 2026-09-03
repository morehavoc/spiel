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

    /// Rotate once to `Spiel.log.1` past this size. The log records every
    /// transcript verbatim (that is what makes it useful when "nothing happened"),
    /// so without a cap it is an unbounded plaintext record of everything dictated.
    static let rotateAtBytes = 5 * 1024 * 1024

    /// Writes a line to `Spiel.log`.
    ///
    /// `sensitive: true` means the line quotes a transcript. Such a line is written
    /// to `Spiel.log` (0600, owner-only — that file IS the debugging deliverable and
    /// he pastes it into the thread deliberately) but is NOT sent to `NSLog`.
    /// `NSLog` goes to the unified system log, which is a different trust boundary:
    /// any admin process can stream it with `log stream`, and every `sysdiagnose`
    /// captures it — so a transcript there leaves the machine inside any diagnostic
    /// bundle sent to Apple or anyone else. Dictation is exactly the kind of text
    /// (passwords, client names, medical) that must not land in a shared log.
    public static func write(_ line: String, sensitive: Bool = false) {
        let text = "[\(stamp.string(from: Date()))] \(line)\n"
        queue.async {
            guard let data = text.data(using: .utf8) else { return }
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int,
               size >= rotateAtBytes {
                let old = url.deletingPathExtension().appendingPathExtension("log.1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
                // A move PRESERVES the mode, so a log that predates this hardening
                // is rotated out still world-readable and then never touched again.
                tighten(fm, at: old.path)
            }
            // Tighten BEFORE the append, and create the file 0600 rather than at the
            // 0644 umask. Doing it afterwards means the first sensitive line of every
            // upgrade lands in a world-readable file, and an fd another local account
            // already holds keeps working regardless of a later chmod.
            if fm.fileExists(atPath: url.path) {
                tighten(fm, at: url.path)
            } else {
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
                tighten(fm, at: url.path)
            }
        }
        if !sensitive { NSLog("Spiel: %@", line) }
    }

    /// 0600 on the log. It holds every transcript verbatim; the home directory is
    /// world-readable-by-default on a multi-user Mac and `~/Library/Logs` is not
    /// TCC-protected, so the default 0644 makes dictation readable by any other
    /// local account and by any unsandboxed process running as another user.
    private static func tighten(_ fm: FileManager, at path: String) {
        let current = (try? fm.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber
        guard current != nil, current?.intValue != 0o600 else { return }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
