import Foundation

/// The last `cap` dictations that produced text — the safety net for a paste that
/// landed in the wrong window, or nowhere.
///
/// A plain JSON file in Application Support, mode 0600, written by temp-file +
/// rename so a crash mid-write leaves the previous complete file. Listen transcripts
/// are NOT here: they already have files of their own.
public struct DictationHistory: Sendable, Equatable {

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var text: String
        public var date: Date
        /// The app the text was aimed at (nil if it could not be captured).
        public var app: String?
        public var words: Int
        public init(id: UUID = UUID(), text: String, date: Date, app: String?, words: Int) {
            self.id = id; self.text = text; self.date = date; self.app = app; self.words = words
        }
    }

    public static let cap = 50

    /// Oldest first; `newestFirst` is what the window shows.
    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = Array(entries.suffix(Self.cap)) }

    public var last: Entry? { entries.last }
    public var newestFirst: [Entry] { entries.reversed() }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Appends and trims to `cap`. Whitespace-only text is not a dictation.
    @discardableResult
    public mutating func add(text: String, app: String?, date: Date = Date()) -> Entry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let e = Entry(text: trimmed, date: date, app: app, words: Self.wordCount(trimmed))
        entries.append(e)
        if entries.count > Self.cap { entries.removeFirst(entries.count - Self.cap) }
        return e
    }

    public mutating func clear() { entries.removeAll() }

    /// Newest first. Every whitespace-separated term must appear in the text or the
    /// app name, case- and diacritic-insensitively. Empty query = everything.
    public func search(_ query: String) -> [Entry] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return newestFirst }
        return newestFirst.filter { e in
            let hay = e.text + " " + (e.app ?? "")
            return terms.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    // MARK: - File

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Spiel", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    private struct FileFormat: Codable { var version: Int; var entries: [Entry] }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(FileFormat(version: 1, entries: entries))
    }

    public static func decode(_ data: Data) throws -> DictationHistory {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return DictationHistory(entries: try dec.decode(FileFormat.self, from: data).entries)
    }

    /// Missing file = empty history, no note. An unreadable or corrupt file = empty
    /// history AND a note, so the app can say why the list is empty; the bad file is
    /// left in place (the next save replaces it) rather than deleted behind his back.
    public static func load(from url: URL = defaultURL) -> (history: DictationHistory, note: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (DictationHistory(), nil) }
        do {
            let data = try Data(contentsOf: url)
            return (try decode(data), nil)
        } catch {
            return (DictationHistory(), "history file could not be read (\(error.localizedDescription)) — starting empty")
        }
    }

    public func save(to url: URL = defaultURL) throws {
        try Self.atomicWrite(try encoded(), to: url)
    }

    /// Temp file in the same folder at 0600, then rename(2) over the target.
    public static func atomicWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = folder.appendingPathComponent(".\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path])
        }
        if rename(tmp.path, url.path) != 0 {
            let err = String(cString: strerror(errno))
            try? fm.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "rename failed: \(err)"])
        }
    }
}
