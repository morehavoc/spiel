import Foundation

/// Where Listen transcripts live on disk, and how they get there without ever
/// leaving a partial file behind.
///
/// One file per session, written continuously (autosave) under the title at the
/// time of each save. A title edit moves the file. Every write goes to a temp file
/// in the same directory and is renamed into place, so a crash mid-write — or a
/// reader opening the file mid-write — sees the previous complete version, never a
/// truncated one.
public enum TranscriptStore {

    /// `~/Documents/Spiel/Transcripts`. A constant, not a setting: the folder
    /// preference is the hand-off doc's and is not added here.
    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Spiel", isDirectory: true)
            .appendingPathComponent("Transcripts", isDirectory: true)
    }

    /// `2026-09-11 1400 Projects Weekly.md`. Empty title → `Untitled`. Characters
    /// a filesystem or Finder chokes on (`/`, `:`, control characters) become `-`;
    /// the title inside the file is untouched. Clipped to 80 characters so a Teams
    /// window title that is a whole agenda still yields a usable name.
    public static func fileName(title: String, startedAt: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = f.string(from: startedAt)
        let safe = sanitize(title)
        return "\(stamp) \(safe.isEmpty ? "Untitled" : safe).md"
    }

    public static func sanitize(_ title: String) -> String {
        var out = ""
        for scalar in title.unicodeScalars {
            if scalar == "/" || scalar == ":" || scalar == "\\" || scalar == "\0"
                || CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar) {
                out.append("-")
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        var trimmed = out.trimmingCharacters(in: .whitespaces)
        // A leading dot hides the file in Finder and `ls`.
        while trimmed.hasPrefix(".") { trimmed.removeFirst() }
        if trimmed.count > 80 {
            trimmed = String(trimmed.prefix(80)).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    /// The URL to save under. If a DIFFERENT file already occupies the name (a
    /// second session with the same title in the same minute), appends ` (2)`,
    /// ` (3)`… `current` is this session's own existing file, which may keep its
    /// name; without it every autosave would step to the next suffix.
    public static func url(for title: String, startedAt: Date, in folder: URL = defaultFolder,
                           current: URL? = nil, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let name = fileName(title: title, startedAt: startedAt)
        let base = String(name.dropLast(3))  // strip ".md"
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while exists(candidate) && candidate.standardizedFileURL != current?.standardizedFileURL {
            candidate = folder.appendingPathComponent("\(base) (\(n)).md")
            n += 1
        }
        return candidate
    }

    public enum StoreError: Error, CustomStringConvertible {
        case folder(String)
        case write(String)
        case rename(String)
        public var description: String {
            switch self {
            case .folder(let s): return "could not create the transcripts folder: \(s)"
            case .write(let s): return "could not write the transcript: \(s)"
            case .rename(let s): return "could not move the transcript into place: \(s)"
            }
        }
    }

    /// Atomic save: temp file beside the target, mode 0600, then rename over it.
    /// If `previous` names a different file from an earlier save (the title
    /// changed), it is removed after the new one is in place — one file per
    /// session, always.
    public static func save(_ text: String, to url: URL, replacing previous: URL? = nil) throws {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            throw StoreError.folder("\(error.localizedDescription)")
        }
        let tmp = folder.appendingPathComponent(".\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp")
        guard let data = text.data(using: .utf8) else { throw StoreError.write("not UTF-8") }
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw StoreError.write("createFile failed at \(tmp.path)")
        }
        // rename(2) is atomic on the same volume and replaces an existing target.
        if rename(tmp.path, url.path) != 0 {
            let err = String(cString: strerror(errno))
            try? fm.removeItem(at: tmp)
            throw StoreError.rename("\(err) (\(url.path))")
        }
        if let previous, previous.standardizedFileURL != url.standardizedFileURL,
           fm.fileExists(atPath: previous.path) {
            try? fm.removeItem(at: previous)
        }
    }
}
