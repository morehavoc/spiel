import Foundation

/// The Listen transcripts on disk, for `spiel transcripts`. Read-only.
public enum ListenTranscripts {

    public struct Item: Sendable, Equatable {
        /// 1 = newest. What `spiel transcripts show 1` means.
        public var number: Int
        public var name: String
        public var path: String
        public var title: String
        public var started: String?
        public var durationSeconds: Int?
        public var words: Int?
    }

    /// Newest first. File names start `yyyy-MM-dd HHmm`, so name order is time
    /// order; a file with no frontmatter still lists, with its name as the title.
    public static func list(in folder: URL = TranscriptStore.defaultFolder) throws -> [Item] {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
            .sorted(by: >)
        return names.enumerated().map { i, name in
            let url = folder.appendingPathComponent(name)
            let head = (try? FileHandle(forReadingFrom: url)).flatMap { h -> String? in
                defer { try? h.close() }
                return String(decoding: h.readData(ofLength: 4096), as: UTF8.self)
            } ?? ""
            let fields = frontmatterFields(head)
            return Item(number: i + 1, name: name, path: url.path,
                        title: fields["title"] ?? String(name.dropLast(3)),
                        started: fields["started"],
                        durationSeconds: fields["duration_s"].flatMap { Int($0) },
                        words: fields["words"].flatMap { Int($0) })
        }
    }

    /// Frontmatter keys from the head of a file (it may be cut mid-body, so the
    /// closing `---` is all that is required).
    static func frontmatterFields(_ head: String) -> [String: String] {
        TranscriptDocument.parseFrontmatter(head)?.fields ?? [:]
    }

    /// `3` → the third newest; otherwise an exact file name (with or without `.md`),
    /// then a unique case-insensitive substring of the name. Ambiguous → nil plus
    /// the candidates, so the caller can say which. A number past the end of the
    /// list is a name fragment, not a miss: `2026` is how every file name starts.
    public static func resolve(_ ref: String, in items: [Item]) -> (item: Item?, candidates: [Item]) {
        if let n = Int(ref), let hit = items.first(where: { $0.number == n }) {
            return (hit, [])
        }
        if let exact = items.first(where: { $0.name == ref || $0.name == ref + ".md" }) { return (exact, []) }
        let hits = items.filter { $0.name.range(of: ref, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return hits.count == 1 ? (hits[0], []) : (nil, hits)
    }
}
