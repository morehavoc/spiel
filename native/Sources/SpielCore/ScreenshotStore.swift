import Foundation

/// Where Listen screenshots go (2.7): a folder beside the transcript, named after
/// it (`2026-09-11 1400 Board review.md` → `2026-09-11 1400 Board review/`), one
/// PNG per shot, `screenshot-12-34.png`. Local files only — nothing here is sent
/// anywhere, and Send Diagnostics never includes them or their paths.
public enum ScreenshotStore {

    /// The folder name for a transcript file: its name without `.md`.
    public static func folderName(forTranscript url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    public static func folder(forTranscript url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(folderName(forTranscript: url), isDirectory: true)
    }

    /// `screenshot-12-34.png`; a second shot in the same second is
    /// `screenshot-12-34-2.png`, then `-3`…
    public static func fileName(offset: TimeInterval, in folder: URL,
                                exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> String {
        let stamp = TranscriptDocument.formatOffset(offset).replacingOccurrences(of: ":", with: "-")
        var name = "screenshot-\(stamp).png"
        var n = 2
        while exists(folder.appendingPathComponent(name)) {
            name = "screenshot-\(stamp)-\(n).png"
            n += 1
        }
        return name
    }

    public enum StoreError: Error, CustomStringConvertible {
        case folder(String)
        case write(String)
        public var description: String {
            switch self {
            case .folder(let s): return "could not create the screenshot folder: \(s)"
            case .write(let s): return "could not write the screenshot: \(s)"
            }
        }
    }

    /// Writes `png` into `folder` (created 0700) as a 0600 file via temp + rename.
    /// Returns the file name used. Errors name no path: the folder is the meeting
    /// title.
    public static func save(_ png: Data, offset: TimeInterval, into folder: URL) throws -> String {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw StoreError.folder(errnoText(error))
        }
        let name = fileName(offset: offset, in: folder)
        let target = folder.appendingPathComponent(name)
        let tmp = folder.appendingPathComponent(".\(name).\(ProcessInfo.processInfo.processIdentifier).tmp")
        guard fm.createFile(atPath: tmp.path, contents: png, attributes: [.posixPermissions: 0o600]) else {
            throw StoreError.write("createFile failed")
        }
        if rename(tmp.path, target.path) != 0 {
            let err = String(cString: strerror(errno))
            try? fm.removeItem(at: tmp)
            throw StoreError.write(err)
        }
        return name
    }

    /// The transcript was renamed (its title changed): move the screenshot folder
    /// `name` (beside the transcript) to match the new file `new`. Returns the
    /// folder name that now holds the screenshots — the new one, or `name` if the
    /// move could not happen (an occupied name, a failure), so links written with
    /// it still resolve.
    public static func follow(_ name: String, to new: URL) -> (name: String, error: String?) {
        let fm = FileManager.default
        let parent = new.deletingLastPathComponent()
        let target = folderName(forTranscript: new)
        guard name != target else { return (name, nil) }
        let from = parent.appendingPathComponent(name, isDirectory: true)
        let to = parent.appendingPathComponent(target, isDirectory: true)
        guard fm.fileExists(atPath: from.path) else { return (name, "the screenshot folder is missing") }
        guard !fm.fileExists(atPath: to.path) else { return (name, "a folder with the new name already exists") }
        do {
            try fm.moveItem(at: from, to: to)
            return (target, nil)
        } catch {
            return (name, errnoText(error))
        }
    }

    /// The POSIX reason, never Foundation's sentence (which quotes file names).
    static func errnoText(_ error: Error) -> String {
        let ns = error as NSError
        if let posix = ns.userInfo[NSUnderlyingErrorKey] as? NSError, posix.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(posix.code)))
        }
        return "\(ns.domain) \(ns.code)"
    }
}
