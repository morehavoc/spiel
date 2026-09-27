import Foundation

/// Help → Send Diagnostics…: a zip a user can attach to a support email.
///
/// PRIVACY IS THE CONTRACT. The bundle carries the state of the machine and the app,
/// never what was said: no transcript text, no dictation history, no vocabulary
/// terms. The report is built only from the facts the caller passes (no field for
/// text exists), and the log tail goes through `redactedLogTail`, which withholds
/// every line `DiagnosticLog` tagged as quoting dictated text and blanks every
/// quoted span on the rest (older logs predate the tag; boost lines quote terms).
/// `spiel-cli selftest` plants secrets and asserts none reach the folder.
public enum DiagnosticsBundle {

    public static let maxLogLines = 2000
    public static let withheldLine = "[line withheld — it quoted dictated text]"

    /// `Key: value` lines under a header. Values are redacted the same way as log
    /// lines, so a quoted string that sneaks into an error message is blanked too.
    public static func report(facts: [(String, String)], generatedAt: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone.current
        let width = facts.map(\.0.count).max() ?? 0
        var out = "Spiel diagnostics — generated \(f.string(from: generatedAt))\n"
        out += "Contains no transcript text, no dictation history and no vocabulary terms.\n\n"
        for (k, v) in facts {
            let value = redactQuotes(v).replacingOccurrences(of: "\n", with: " ")
            out += k.padding(toLength: width, withPad: " ", startingAt: 0) + " : " + value + "\n"
        }
        return out
    }

    /// Blanks everything from the first `"` to the last one on the line (a
    /// transcript can itself contain quotes, so pairing them would leak the middle).
    /// A lone quote blanks to the end of the line.
    public static func redactQuotes(_ line: String) -> String {
        guard let first = line.firstIndex(of: "\"") else { return line }
        let last = line.lastIndex(of: "\"")!
        if first == last { return String(line[..<first]) + "\"[redacted]" }
        return String(line[..<first]) + "\"[redacted]\"" + String(line[line.index(after: last)...])
    }

    public static func redactLine(_ line: String) -> String {
        if line.contains(DiagnosticLog.sensitiveTag) {
            // Keep the timestamp so the timeline still reads.
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                return String(line[...close]) + " " + withheldLine
            }
            return withheldLine
        }
        return redactTranscriptNames(redactQuotes(line))
    }

    /// Listen files are named after the meeting title (`2026-09-11 1400 Board
    /// review.md`), and the title is blanked where it is quoted — so it must not
    /// come back as a file name in `saved to …` or a `/Transcripts/…` path.
    public static func redactTranscriptNames(_ line: String) -> String {
        var out = line
        for pattern in [#"saved to .*?\.md"#, #"/Transcripts/.*?\.md"#] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(out.startIndex..., in: out)
            let replacement = pattern.hasPrefix("saved") ? "saved to [transcript file]" : "/Transcripts/[transcript file]"
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: replacement)
        }
        return out
    }

    /// The last `maxLines` lines of the log, each redacted.
    public static func redactedLogTail(_ text: String, maxLines: Int = maxLogLines) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let trimmed = lines.last == "" ? Array(lines.dropLast()) : lines
        return trimmed.suffix(maxLines).map(redactLine).joined(separator: "\n") + "\n"
    }

    /// Writes `report.txt` (and `Spiel-log-tail.txt` when the log exists) into
    /// `folder`, which is created. Returns the files written.
    @discardableResult
    public static func write(facts: [(String, String)], logURL: URL, into folder: URL,
                             generatedAt: Date = Date()) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var written: [URL] = []
        var facts = facts
        let logNote: String
        if let data = fm.contents(atPath: logURL.path), let text = String(data: data, encoding: .utf8) {
            let tail = redactedLogTail(text)
            let url = folder.appendingPathComponent("Spiel-log-tail.txt")
            try tail.write(to: url, atomically: true, encoding: .utf8)
            written.append(url)
            logNote = "included (last \(min(maxLogLines, tail.split(separator: "\n").count)) lines, redacted)"
        } else {
            logNote = "not present (Diagnostic Logging was off, or nothing written yet)"
        }
        facts.append(("Spiel.log", logNote))
        let report = folder.appendingPathComponent("report.txt")
        try self.report(facts: facts, generatedAt: generatedAt).write(to: report, atomically: true, encoding: .utf8)
        written.insert(report, at: 0)
        return written
    }

    /// `ditto -c -k --keepParent folder zip` — the same archiver Finder uses.
    public static func zip(folder: URL, to zipURL: URL) throws {
        try? FileManager.default.removeItem(at: zipURL)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-c", "-k", "--keepParent", folder.path, zipURL.path]
        let pipe = Pipe()
        task.standardError = pipe
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "ditto failed: \(err)"])
        }
    }

    // MARK: - Facts that do not need the app

    public static func chip() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public static var modelsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
    }

    /// Each model folder FluidAudio has downloaded, with its size on disk.
    public static func modelInventory(in folder: URL = modelsFolder) -> String {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return "none (\(folder.path) absent)" }
        let parts = names.filter { !$0.hasPrefix(".") }.sorted().map { name -> String in
            var bytes: Int64 = 0
            if let e = fm.enumerator(at: folder.appendingPathComponent(name), includingPropertiesForKeys: [.fileSizeKey]) {
                for case let u as URL in e {
                    bytes += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            }
            return "\(name) (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))"
        }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }
}
