import Foundation

/// The in-memory transcript for one Listen session, and its rendering. Pure: no
/// I/O, no clock of its own except the `now` a caller passes for the panel's
/// "recent" tint.
///
/// The session says WHEN a segment happened (`startOffset`, `gapBefore`, both from
/// the sample counter); this type decides where paragraphs go. Offsets it displays
/// are wall-clock-true for the reader: every pause the app records is added back as
/// an explicit correction, because the session's counter only advances while audio
/// arrives and a reader's "[31:07]" should mean 31 minutes into the meeting, not 31
/// minutes of unpaused audio.
public struct TranscriptDocument: Sendable, Equatable {

    public struct Paragraph: Sendable, Equatable {
        /// Display offset in seconds — sample-counted, plus the pause correction.
        public var offset: TimeInterval
        public var text: String
        /// Marker lines (`[paused 4 min]`, `[input changed …]`, `[missed …]`) are
        /// their own paragraphs and never get speech glued onto them.
        public var isMarker: Bool
        /// A screenshot marker (2.7): the PNG's file name inside the transcript's
        /// screenshot folder. The folder is named after the transcript file, which
        /// moves when the title changes, so it is supplied at render time.
        public var image: String?
        /// Wall clock of the last append, for the panel's recency tint only.
        public var appendedAt: Date
        /// Raw (uncorrected) onset of the FIRST segment in this paragraph, for the
        /// monologue cap.
        var rawStart: TimeInterval
    }

    public private(set) var paragraphs: [Paragraph] = []
    /// Same value as `DictationSession.Config.paragraphGap`, held here so a
    /// document can be tested without a session.
    public var paragraphGap: TimeInterval = 2.0
    /// A monologue still gets a break: a paragraph whose speech spans this long
    /// starts a new one at the next segment.
    public var monologueCap: TimeInterval = 90
    /// Total paused time recorded so far; added to every later raw offset.
    public private(set) var pauseCorrection: TimeInterval = 0

    public init() {}

    // MARK: - Building

    /// One released segment. Starts a new paragraph on a long gap, on the monologue
    /// cap, after a marker, or when there is nothing yet; otherwise extends the
    /// current one with a space and `tidy`.
    public mutating func append(text: String, startOffset: TimeInterval, gapBefore: TimeInterval, now: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let at = insertionIndex(forDisplayOffset: startOffset + pauseCorrection)
        if let last = at > 0 ? paragraphs[at - 1] : nil, !last.isMarker,
           gapBefore < paragraphGap,
           startOffset - last.rawStart < monologueCap {
            var p = last
            p.text = TranscriptAssembler.tidy(p.text + " " + trimmed)
            p.appendedAt = now
            paragraphs[at - 1] = p
        } else {
            paragraphs.insert(Paragraph(
                offset: startOffset + pauseCorrection, text: TranscriptAssembler.tidy(trimmed),
                isMarker: false, appendedAt: now, rawStart: startOffset
            ), at: at)
        }
    }

    /// Where speech starting at `displayOffset` goes: before any trailing
    /// screenshots taken after it. A segment is released a second or more after
    /// its onset (longer for a long sentence), so a screenshot taken mid-sentence
    /// is already in the document when that sentence arrives.
    private func insertionIndex(forDisplayOffset displayOffset: TimeInterval) -> Int {
        var i = paragraphs.count
        while i > 0, paragraphs[i - 1].image != nil, paragraphs[i - 1].offset > displayOffset { i -= 1 }
        return i
    }

    /// A screenshot taken at raw audio offset `atOffset`. `pausedFor` is how long
    /// the current pause has run (0 when not paused): the audio counter stands
    /// still during a pause, and the pause itself is booked only when it ends.
    public mutating func addScreenshot(file: String, atOffset: TimeInterval, pausedFor: TimeInterval = 0, now: Date = Date()) {
        let offset = atOffset + pauseCorrection + max(0, pausedFor)
        var p = Paragraph(offset: offset, text: "[\(Self.formatOffset(offset))] Screenshot", isMarker: true,
                          appendedAt: now, rawStart: atOffset)
        p.image = file
        paragraphs.append(p)
    }

    /// Capture was paused for `seconds`, at raw audio offset `atOffset`. Later
    /// offsets shift by the pause so they stay wall-clock-true.
    public mutating func notePause(seconds: TimeInterval, atOffset: TimeInterval, now: Date = Date()) {
        guard seconds > 0 else { return }
        addMarker("[paused \(Self.formatDuration(seconds))]", rawOffset: atOffset, now: now)
        pauseCorrection += seconds
    }

    /// Capture restarted on a new input device (or after sleep) at `atOffset`.
    public mutating func noteCaptureRestart(device: String, atOffset: TimeInterval, now: Date = Date()) {
        let name = device.trimmingCharacters(in: .whitespacesAndNewlines)
        addMarker("[input changed to \(name.isEmpty ? "unknown device" : name) at \(Self.formatOffset(atOffset + pauseCorrection))]",
                  rawOffset: atOffset, now: now)
    }

    /// The engine failed on a segment: a hole of about `seconds` at `atOffset`.
    public mutating func noteMissed(seconds: TimeInterval, atOffset: TimeInterval, now: Date = Date()) {
        addMarker("[missed ~\(Int(seconds.rounded())) s at \(Self.formatOffset(atOffset + pauseCorrection))]",
                  rawOffset: atOffset, now: now)
    }

    /// Markers go at the end, except before trailing screenshots that are later
    /// than them — a pause marker is booked when the pause ENDS, after any
    /// screenshot taken during it.
    private mutating func addMarker(_ text: String, rawOffset: TimeInterval, now: Date) {
        let offset = rawOffset + pauseCorrection
        paragraphs.insert(Paragraph(offset: offset, text: text, isMarker: true, appendedAt: now, rawStart: rawOffset),
                          at: insertionIndex(forDisplayOffset: offset))
    }

    // MARK: - Reading

    /// Words of speech; marker lines do not count.
    public var wordCount: Int {
        paragraphs.filter { !$0.isMarker }
            .reduce(0) { $0 + $1.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count }
    }

    public var isEmpty: Bool { paragraphs.isEmpty }

    /// Seconds since the newest paragraph changed, or nil with no paragraphs.
    public func lastParagraphAge(now: Date = Date()) -> TimeInterval? {
        paragraphs.last.map { now.timeIntervalSince($0.appendedAt) }
    }

    /// The transcript without frontmatter, for Copy. `plain: true` drops the
    /// `[MM:SS]` prefixes and marker lines — text only. `screenshots` is the name
    /// of the screenshot folder beside the transcript file (see `ScreenshotStore`).
    public func body(plain: Bool = false, screenshots: String = "") -> String {
        let lines: [String] = paragraphs.compactMap { p in
            if plain {
                return p.isMarker ? nil : p.text
            }
            if let image = p.image {
                return Self.imageLine(offset: p.offset, folder: screenshots, file: image)
            }
            return p.isMarker ? p.text : "[\(Self.formatOffset(p.offset))] \(p.text)"
        }
        return lines.joined(separator: "\n\n")
    }

    public struct Frontmatter: Sendable {
        public var title: String
        public var startedAt: Date
        public var endedAt: Date
        public var version: String
        public var inputDevice: String
        public var engine: String
        public init(title: String, startedAt: Date, endedAt: Date, version: String, inputDevice: String, engine: String) {
            self.title = title; self.startedAt = startedAt; self.endedAt = endedAt
            self.version = version; self.inputDevice = inputDevice; self.engine = engine
        }
    }

    /// The whole file: YAML frontmatter (the hand-off doc's §2c, verbatim keys) and
    /// the body. `started`/`ended` are ISO 8601 WITH offset — a receiver keys on
    /// them, and naive local time is ambiguous twice a year.
    public func render(frontmatter f: Frontmatter, screenshots: String = "") -> String {
        let duration = max(0, Int(f.endedAt.timeIntervalSince(f.startedAt).rounded()))
        var out = "---\n"
        out += "app: Spiel\n"
        out += "spiel_version: \(Self.yaml(f.version))\n"
        out += "kind: transcript\n"
        out += "title: \(Self.yaml(f.title.isEmpty ? "Untitled" : f.title))\n"
        out += "started: \(Self.iso8601(f.startedAt))\n"
        out += "ended: \(Self.iso8601(f.endedAt))\n"
        out += "duration_s: \(duration)\n"
        out += "words: \(wordCount)\n"
        out += "source: microphone\n"
        out += "input_device: \(Self.yaml(f.inputDevice))\n"
        out += "engine: \(Self.yaml(f.engine))\n"
        out += "---\n\n"
        out += body(screenshots: screenshots)
        out += "\n"
        return out
    }

    /// `![Screenshot 12:34](2026-09-11%201400%20Board%20review/screenshot-12-34.png)`:
    /// an inline image in any Markdown viewer, relative to the transcript file.
    public static func imageLine(offset: TimeInterval, folder: String, file: String) -> String {
        let path = folder.isEmpty ? file : folder + "/" + file
        return "![Screenshot \(formatOffset(offset))](\(encodePath(path)))"
    }

    /// Percent-encodes everything but unreserved characters and `/`. Spaces and
    /// parentheses would end a Markdown link early; non-ASCII titles encode as UTF-8.
    public static func encodePath(_ path: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~/")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    /// Parses the frontmatter `render` wrote. Returns the key/value map and the
    /// body, or nil if the text does not start with a frontmatter block. Exists
    /// so a selftest can prove `render` round-trips; a receiver would use its own.
    public static func parseFrontmatter(_ text: String) -> (fields: [String: String], body: String)? {
        guard text.hasPrefix("---\n") else { return nil }
        let rest = text.dropFirst(4)
        guard let end = rest.range(of: "\n---\n") else { return nil }
        var fields: [String: String] = [:]
        for line in rest[..<end.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            fields[key] = value
        }
        let body = String(rest[end.upperBound...]).trimmingCharacters(in: .newlines)
        return (fields, body)
    }

    // MARK: - Formatting

    /// `MM:SS`, minutes unbounded — a 75-minute meeting reads `[75:12]`, which is
    /// what a reader scanning for "about an hour and a quarter in" wants.
    public static func formatOffset(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// `4 min`, `45 s`, `1 h 12 min` — for marker lines and the done state.
    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        return "\(m / 60) h \(m % 60) min"
    }

    static func iso8601(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxxxx"  // xxxxx: +00:00 in UTC, never "Z"
        return f.string(from: d)
    }

    /// Quote a YAML scalar only when it needs it: a title with a colon, a leading
    /// symbol, or quotes would otherwise change the document's shape.
    static func yaml(_ s: String) -> String {
        let needs = s.isEmpty || s.contains(":") || s.contains("#") || s.contains("\"")
            || s.hasPrefix("-") || s.hasPrefix("[") || s.hasPrefix("{") || s.hasPrefix("'")
            || s.hasPrefix("&") || s.hasPrefix("*") || s.hasPrefix("!") || s.hasPrefix("|")
            || s.hasPrefix(">") || s.hasPrefix("%") || s.hasPrefix("@") || s.hasPrefix("`")
            || s.contains("\n") || s != s.trimmingCharacters(in: .whitespaces)
        guard needs else { return s }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }
}
