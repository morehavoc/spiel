import Foundation

/// Menu → Install Command Line Tool…: a symlink from a bin folder to the `spiel`
/// binary inside the app bundle. No sudo, ever — the default folder is the user's
/// own `~/.local/bin`, and `/usr/local/bin` is offered only when it is writable.
public enum CommandLineInstaller {

    public static var userBin: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
    }
    public static let systemBin = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
    public static let toolName = "spiel"

    /// Where bundle.sh puts the tool: `Spiel.app/Contents/Helpers/spiel` (not
    /// Contents/MacOS — APFS is case-insensitive, and `spiel` there IS `Spiel`).
    public static func helper(in bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Helpers/\(toolName)")
    }

    public enum Outcome: Equatable, Sendable {
        case installed(String)
        case replaced(String, previous: String)
        case alreadyInstalled(String)
    }

    public enum InstallError: Error, CustomStringConvertible, Equatable {
        case helperMissing(String)
        case translocated
        case occupied(String)
        case cannotCreate(String)
        public var description: String {
            switch self {
            case .helperMissing(let p): return "the spiel tool is missing from this copy of Spiel (\(p)) — rebuild or reinstall the app"
            case .translocated:
                return "macOS is running Spiel from a temporary, read-only location (App Translocation). Move Spiel.app to /Applications, open it from there, and try again."
            case .occupied(let p): return "\(p) already exists and is not a link to Spiel — it was left alone. Remove it yourself if it is not needed."
            case .cannotCreate(let s): return s
            }
        }
    }

    /// Creates `dir` if needed and points `dir/spiel` at `helper`. An existing link
    /// that already points there is left; one that points at another Spiel app's
    /// helper (an older copy) is replaced; anything else is refused, never clobbered.
    public static func install(helper: URL, into dir: URL) throws -> Outcome {
        let fm = FileManager.default
        guard !helper.path.contains("/AppTranslocation/") else { throw InstallError.translocated }
        guard fm.isExecutableFile(atPath: helper.path) else { throw InstallError.helperMissing(helper.path) }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw InstallError.cannotCreate("could not create \(dir.path): \(error.localizedDescription)")
        }
        let link = dir.appendingPathComponent(toolName)
        var previous: String?
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            if dest == helper.path { return .alreadyInstalled(link.path) }
            guard dest.hasSuffix(".app/Contents/Helpers/\(toolName)") else { throw InstallError.occupied(link.path) }
            previous = dest
            do { try fm.removeItem(at: link) } catch {
                throw InstallError.cannotCreate("could not replace \(link.path): \(error.localizedDescription)")
            }
        } else if fm.fileExists(atPath: link.path) {
            throw InstallError.occupied(link.path)
        }
        do {
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: helper.path)
        } catch {
            throw InstallError.cannotCreate("could not create \(link.path): \(error.localizedDescription)")
        }
        return previous.map { .replaced(link.path, previous: $0) } ?? .installed(link.path)
    }

    /// Whether `dir` is one of the entries of a `PATH` string (a trailing slash and
    /// a `~` spelling both count).
    public static func isOnPath(_ dir: URL, path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let want = dir.standardizedFileURL.path
        return path.split(separator: ":").contains { entry in
            var e = String(entry)
            if e.hasPrefix("~") { e = home + e.dropFirst() }
            return URL(fileURLWithPath: e).standardizedFileURL.path == want
        }
    }

    /// The PATH an interactive login shell would have — a GUI app's own PATH is
    /// launchd's, not the user's. nil if the shell did not answer within `timeout`.
    public static func loginShellPATH(timeout: TimeInterval = 3) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: shell)
        // A marker, because an interactive rc file may print its own output.
        task.arguments = ["-l", "-i", "-c", "printf '\\n__SPIEL_PATH__%s\\n' \"$PATH\""]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if task.isRunning { task.terminate(); return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("__SPIEL_PATH__") }) else { return nil }
        return String(line.dropFirst("__SPIEL_PATH__".count))
    }
}
