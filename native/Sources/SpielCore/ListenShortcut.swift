import Foundation

/// "Run a Shortcut when Listen stops" (2.8). Spiel hands the saved transcript file to
/// one Shortcut the user picked in Settings, through Apple's own `shortcuts` command.
/// Spiel knows nothing about what the Shortcut does; no network code lives here.
public enum ListenShortcut {
    public static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")

    /// The transcript goes in as a file, so the Shortcut receives the Markdown
    /// (frontmatter included) whatever its length.
    public static func arguments(name: String, file: URL) -> [String] {
        ["run", name, "--input-path", file.path]
    }

    /// The user's Shortcuts, sorted. Empty when the command fails (logged).
    public static func list() -> [String] {
        let r = runSync(["list"], timeout: 15)
        guard r.status == 0 else {
            DiagnosticLog.write("shortcuts list failed (\(r.status)): \(r.stderr)")
            return []
        }
        return r.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public struct Outcome: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public let timedOut: Bool
        public var ok: Bool { status == 0 && !timedOut }
    }

    /// Runs off the main thread; `done` is called on the main queue. A Shortcut that
    /// waits for input forever is stopped after `timeout` seconds.
    public static func run(name: String, file: URL, timeout: TimeInterval = 600,
                           done: @escaping @Sendable (Outcome) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let r = runSync(arguments(name: name, file: file), timeout: timeout)
            DispatchQueue.main.async { done(r) }
        }
    }

    public static func runSync(_ args: [String], timeout: TimeInterval) -> Outcome {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            return Outcome(status: -1, stdout: "", stderr: "\(error)", timedOut: false)
        }
        let finished = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in finished.signal() }
        // Drain both pipes while it runs, so a chatty Shortcut cannot block on a full pipe.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if finished.wait(timeout: .now() + 5) == .timedOut { kill(p.processIdentifier, SIGKILL); finished.wait() }
        }
        group.wait()
        let clip = { (d: Data) in String(decoding: d.prefix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        return Outcome(status: p.terminationStatus, stdout: clip(outData), stderr: clip(errData), timedOut: timedOut)
    }
}
