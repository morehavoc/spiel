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
        "ArcGIS": ["arc gis", "arcgis", "ark gis", "arc jis", "arc g i s"],
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
