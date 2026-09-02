import Foundation

/// Post-transcription vocabulary correction.
///
/// This exists because of a measured gap: Argmax's M4 benchmark notes that Apple's
/// new `SpeechTranscriber` DROPPED the Custom Vocabulary feature its older API had,
/// and Parakeet has no vocabulary-biasing hook either. For a user whose dictation is
/// full of ArcGIS, GeoJSON, AGOL and dymaptic, that gap is the whole ballgame -- so
/// the fix lives here, downstream of whichever engine ran, rather than inside one.
///
/// Deliberately NOT a regex over free prose. Matching is whole-token, case-insensitive
/// on a fixed alias list. Substring matching would rewrite "scarcity" into
/// "scARcGISty" and "flagol" into "flAGOL"; loose patterns over prose produce
/// confident wrong answers, which is worse than leaving a word misspelled.
public struct Glossary: Sendable {
    /// alias (lowercased, no punctuation) -> canonical spelling
    private var map: [String: String]

    public init(entries: [String: [String]] = Glossary.defaultEntries) {
        var m: [String: String] = [:]
        for (canonical, aliases) in entries {
            m[Glossary.normalize(canonical)] = canonical
            for alias in aliases {
                m[Glossary.normalize(alias)] = canonical
            }
        }
        self.map = m
    }

    public var count: Int { map.count }

    /// Christopher's actual working vocabulary. Aliases are the plausible
    /// mis-transcriptions, not every possible one -- an alias that collides with a
    /// real English word does more harm than the miss it fixes.
    public static let defaultEntries: [String: [String]] = [
        // "ArcJS" observed from Parakeet on 2026-09-02 (Christopher said ArcGIS).
        "ArcGIS": ["arc gis", "arcgis", "ark gis", "arc jis", "arc g i s", "arcjs", "arc js", "arc j s", "arc js"],
        // "g ojson" observed from Parakeet on 2026-09-02. Safe to alias: it is not
        // an English word, unlike "arc just" (Apple's ArcGIS miss), which is a
        // plausible bigram and is deliberately NOT listed.
        "GeoJSON": ["geo json", "geojson", "geo jason", "geo j son", "g ojson", "gojson"],
        "Esri": ["esri", "ezri", "esry", "ess ri"],
        "dymaptic": ["dymaptic", "die maptic", "dymatic", "dynamaptic", "di maptic"],
        "AGOL": ["agol", "a gol", "a g o l"],
        "Survey123": ["survey 123", "survey123", "survey one twenty three"],
        "Whisperframe": ["whisper frame", "whisperframe"],
        "ArcPy": ["arc py", "arcpy", "arc pie"],
        "GIS": ["g i s"],
        "Parakeet": ["parakeet", "para keet"],
        "Whisper": ["whisper"],
        "Xcode": ["x code", "xcode"],
        "macOS": ["mac os", "macos"],
        "JAWS": ["jaws"],
        "Nexus": ["nexus"],
        "Tailscale": ["tail scale", "tailscale"],
        "Ollama": ["olama", "ollama", "oh lama"],
    ]

    // MARK: - User-editable vocabulary file
    //
    // Christopher, 2026-09-02: "how do I edit the special words that the model can
    // use to understand things like GeoJSON or ArcGIS or Esri?" The list above is
    // compiled in; this file is his. Format, one term per line:
    //
    //     # comment
    //     ArcGIS: arc gis, arcjs, ark gis
    //     dymaptic: die maptic, dymatic
    //
    // Left of the colon is the spelling you want; right of it, comma-separated, the
    // ways the engine tends to hear it. A line with no colon adds the word with no
    // aliases (still fixes capitalisation). User entries are merged over the
    // built-ins, and a user alias wins if both define it.

    public static let userFileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Spiel", isDirectory: true)
        return dir.appendingPathComponent("vocabulary.txt")
    }()

    /// Parses the file format above. Never throws on bad lines — a typo in the
    /// vocabulary must not take dictation down; the line is skipped.
    public static func parse(_ text: String) -> [String: [String]] {
        var entries: [String: [String]] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let canonical = parts[0].trimmingCharacters(in: .whitespaces)
            guard !canonical.isEmpty else { continue }
            let aliases = parts.count > 1
                ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : []
            entries[canonical, default: []].append(contentsOf: aliases)
        }
        return entries
    }

    /// Built-ins merged with the user file (user wins on conflicts). Missing or
    /// unreadable file → built-ins only.
    public static func load(userFile: URL = userFileURL) -> Glossary {
        var entries = defaultEntries
        if let text = try? String(contentsOf: userFile, encoding: .utf8) {
            for (canonical, aliases) in parse(text) {
                entries[canonical, default: []].append(contentsOf: aliases)
            }
        }
        return Glossary(entries: entries)
    }

    /// Renders entries in the file format (sorted, so the template is stable).
    public static func render(_ entries: [String: [String]]) -> String {
        entries.keys.sorted { $0.lowercased() < $1.lowercased() }
            .map { k in entries[k]!.isEmpty ? k : "\(k): \(entries[k]!.joined(separator: ", "))" }
            .joined(separator: "\n") + "\n"
    }

    /// Creates the user file from the built-ins on first use, so there is something
    /// to edit and the format is self-explanatory. Returns the URL.
    @discardableResult
    public static func ensureUserFile(at url: URL = userFileURL) -> URL {
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = """
        # Spiel vocabulary — one term per line.
        #   Spelling you want: how the engine hears it, another way, ...
        # Matching is whole-word and case-insensitive. Avoid aliases that are real
        # English words (e.g. "arc just") — they would rewrite normal sentences.
        # Edit, save, and the next dictation picks it up. Delete this file to reset.

        """
        try? (header + render(defaultEntries)).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Applies the glossary to a transcript.
    ///
    /// Walks the token stream and tries the longest multi-word alias first (up to
    /// 4 tokens), so "arc gis" beats a hypothetical "arc". Punctuation attached to a
    /// token is preserved.
    public func apply(to text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard !tokens.isEmpty else { return text }

        var out: [String] = []
        var i = 0
        let maxSpan = 4

        while i < tokens.count {
            var matched = false
            let remaining = min(maxSpan, tokens.count - i)
            if remaining > 0 {
                for span in stride(from: remaining, through: 1, by: -1) {
                    let slice = tokens[i..<(i + span)]
                    // Only the LAST token may carry trailing punctuation; interior
                    // punctuation means this isn't a single term.
                    let joined = slice.joined(separator: " ")
                    let (core, trailing) = Glossary.splitTrailingPunctuation(joined)
                    let interior = slice.dropLast().joined()
                    if interior.contains(where: { $0.isPunctuation }) { continue }

                    if let canonical = map[Glossary.normalize(core)] {
                        out.append(canonical + trailing)
                        i += span
                        matched = true
                        break
                    }
                }
            }
            if !matched {
                out.append(tokens[i])
                i += 1
            }
        }
        return out.joined(separator: " ")
    }

    static func splitTrailingPunctuation(_ s: String) -> (String, String) {
        var core = s
        var trailing = ""
        while let last = core.last, last.isPunctuation || last.isSymbol {
            trailing = String(last) + trailing
            core.removeLast()
        }
        return (core, trailing)
    }
}
