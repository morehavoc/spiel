import AppKit
import Foundation
import FluidAudio

/// NVIDIA Parakeet Unified EN 0.6B via FluidAudio's batch path — the default engine
/// since 2.2.0 (2026-09-23).
///
/// Chosen on Christopher's own voice, not a vendor table: five clips (a walking
/// video, a short, two conference-talk clips and six minutes of a talk; 1,899 words
/// against hand-corrected captions) through the real dictation pipeline scored
/// aggregate WER 6.7 % for this model vs 11.2 % for TDT v3, 8.5 % for TDT v2 and
/// 10.4 % for Apple's SpeechAnalyzer. v3 (multilingual) also returned an EMPTY
/// transcript for one whole 13 s segment of the talk — a dropped chunk the
/// assembler cannot see. Same parameter count as v3; English-only, punctuated.
///
/// No decoder state is carried between calls (the batch path has none), so
/// `resetContext()` is the protocol's no-op default.
public actor ParakeetUnifiedTranscriber: Transcriber {
    public nonisolated let kind: TranscriberKind = .parakeet
    private var manager: UnifiedAsrManager?

    // Acoustic vocabulary boost (FluidAudio CTC word-spotter, NeMo arXiv:2406.07096):
    // a separate Parakeet CTC 110M encoder scores the same audio for each term on the
    // user's list, and the rescorer swaps a transcript word for a term only when the
    // term has the stronger acoustic evidence. Optional by construction — any failure
    // here leaves plain transcription running. Since 2.3.1 the session is held here,
    // not inside the manager, so every rewrite passes `guardRepairs` before it lands.
    private let boostEnabled: Bool
    private var ctcModels: CtcModels?
    private var ctcTokenizer: CtcTokenizer?
    private var boosting: VocabularyBoostingSession?
    private var boostedVocabulary: [String: [String]]?
    public private(set) var boostTermCount = 0
    public private(set) var boostError: String?

    public init(boost: Bool = true) { self.boostEnabled = boost }

    // Frozen 2026-09-23 on 1,899 words of Christopher's speech + 435 words of
    // jargon-dense TTS (spiel-cli replay, user vocabulary loaded in both arms):
    //   no boost: 127 / 18 errors;  minSim 0.80 + neighbour 0.9 + one-word terms:
    //   127 / 8 — zero changes on real speech, 7 changes on jargon, all correct.
    //   minSim 0.75: 132 / 10 ("part" → UART, "Mac" → HMAC). All terms, no filter:
    //   382 / 104.
    public static let minSimilarity: Float = 0.80
    static let neighbourSimilarity: Double = 0.9

    /// The spotter-anchored "acoustic rescue" pass is OFF, whatever the list size.
    ///
    /// FluidAudio runs that pass only when the list has 10 terms or fewer, and it lets
    /// the CTC spotter swap a term in over a word that looks nothing like it (the
    /// 0.30 floor below is the only string check it gets). 2.3.0 was measured with a
    /// 249-term list (73 boosted), where the pass never runs; the built-in list alone
    /// boosts 7 terms, where it does — and Christopher's dictation from Sep 23 on
    /// carried "CEOs" → GeoJSON three times in one message, which only this pass can
    /// produce (similarity 0.43, under the main path's 0.80). `boost-eval` caught it
    /// live on TTS: "processes." → ArcGIS, "pie." → ArcPy. With the pass off, a
    /// replacement needs a transcript word within `minSimilarity` of the term or one
    /// of its aliases ("Olima" → Ollama), the same gate at every list size.
    public static let rescorerConfig = VocabularyRescorer.Config(
        spotterRescueMinSimilarity: 0.30,
        spotterRescueMultiWordMinSimilarity: 0.50,
        spotterRescueEnabled: false)

    /// The rescorer settings 2.3.0 shipped with — rescue pass on for short lists.
    /// Kept only so `spiel-cli boost-eval` can show the difference; nothing ships it.
    public static let rescorerConfig230 = VocabularyRescorer.Config(
        spotterRescueMinSimilarity: 0.30,
        spotterRescueMultiWordMinSimilarity: 0.50)

    public func prepare() async throws {
        if manager != nil { return }
        do {
            let m = UnifiedAsrManager()
            try await m.loadModels()
            manager = m
        } catch {
            throw TranscriberError.unavailable("Parakeet Unified model load failed: \(error)")
        }
    }

    public func setVocabulary(_ entries: [String: [String]]) async {
        guard boostEnabled, manager != nil, entries != boostedVocabulary else { return }
        do {
            if ctcModels == nil {
                ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
                ctcTokenizer = try await CtcTokenizer.load(
                    from: CtcModels.defaultCacheDirectory(for: .ctc110m))
            }
            guard let ctcModels, let ctcTokenizer else { return }
            let terms = Self.boostTerms(entries, tokenizer: ctcTokenizer)
            boosting = try await VocabularyBoostingSession(
                vocabulary: Self.boostContext(terms),
                ctcModels: ctcModels,
                config: Self.rescorerConfig)
            boostedVocabulary = entries
            boostTermCount = terms.count
            boostError = nil
            DiagnosticLog.write("vocabulary boost configured: \(terms.count) of \(entries.count) terms (\(entries.count - terms.count) left to the text glossary as near-English)")
        } catch {
            boostError = "\(error)"
            DiagnosticLog.write("vocabulary boost unavailable (plain transcription continues): \(error)")
        }
    }

    /// The boost list built from the vocabulary: boostable canonicals only, each with
    /// its aliases. Public so `spiel-cli boost-eval` scores exactly what the app boosts.
    public static func boostTerms(_ entries: [String: [String]], tokenizer: CtcTokenizer) -> [CustomVocabularyTerm] {
        entries.keys.sorted().filter { isBoostable($0) }.compactMap { canonical in
            let ids = tokenizer.encode(canonical)
            guard !ids.isEmpty else { return nil }
            let aliases = entries[canonical] ?? []
            return CustomVocabularyTerm(
                text: canonical, aliases: aliases.isEmpty ? nil : aliases, ctcTokenIds: ids)
        }
    }

    public static func boostContext(_ terms: [CustomVocabularyTerm]) -> CustomVocabularyContext {
        CustomVocabularyContext(terms: terms, minSimilarity: minSimilarity)
    }

    /// Whether a vocabulary term is safe to boost acoustically.
    ///
    /// Measured 2026-09-23: boosting every term on the list rewrote ordinary speech
    /// ("code" → "Codex", "more" → "MoE", "things" → "Airthings"). The misfires are
    /// terms that ARE English words, or sit one edit from one, or split into English
    /// words. Those the main model already spells as English, and the text glossary
    /// (aliases like "air things") repairs them without any acoustic guess. So the
    /// boost only gets terms the macOS spell-checker says are not words and have no
    /// close dictionary neighbour — Deskbot, Newsologue, GeoBlazor, dymaptic.
    public static func isBoostable(_ term: String) -> Bool {
        let norm = Self.normalize(term)
        guard norm.count >= 4 else { return false }
        // One word only: a multi-word term lets the rescorer take a neighbouring word
        // into the span it replaces ("to ArcGIS Online" → "ArcGIS Online", measured).
        guard !term.contains(" ") else { return false }
        let lower = term.lowercased()
        if spelledCorrectly(lower) { return false }  // it is an English word (or words)
        let range = NSRange(location: 0, length: (lower as NSString).length)
        spellLock.lock()
        let guesses = NSSpellChecker.shared.guesses(forWordRange: range, in: lower, language: "en",
                                                    inSpellDocumentWithTag: 0) ?? []
        spellLock.unlock()
        return !guesses.contains { Self.similarity(Self.normalize($0), norm) >= neighbourSimilarity }
    }

    // MARK: - Guard: the boost repairs non-words, it never overwrites English

    /// One rewrite the boost proposed for a segment, and whether it was kept.
    public struct BoostRepair: Sendable, Equatable {
        public let from: String   // the words as first transcribed
        public let to: String     // what the boost wanted there
        public let kept: Bool
        public init(from: String, to: String, kept: Bool) { self.from = from; self.to = to; self.kept = kept }
    }

    /// Keeps a boost rewrite only where the words it replaces include a NON-word.
    ///
    /// Measured 2026-09-25 (`spiel-cli boost-eval`, built-in list, rescue pass off):
    /// the similarity-gated path still rewrote "a goal" → AGOL in 6 of 6 and "Llama" /
    /// "llama" → Ollama in 6 of 6 — alias "a gol" is 0.83 from "a goal", "ollama" 0.83
    /// from "llama", and the audio matches because the words sound alike. With the
    /// 249-term list it rewrote "no no no no" → "Hono Hono", "post is" → PostGIS,
    /// "open a" → OpenAI in 2.6 h of real speech. Every misfire in Christopher's
    /// messages since 2.3.0 overwrote a real word too ("CEOs", "what", "app"). The
    /// boost exists for what the engine MISHEARS as gibberish — "Olama", "Ezri",
    /// "GOJSON", "Dimaptic" — so that is all it may touch. An English word he really
    /// does mean as a term ("a goal" for AGOL) is the text glossary's job: an alias he
    /// chose, not an acoustic guess. Cost, on 84 TTS clips: 9 of 23 correct repairs
    /// lost, all where the engine heard the term AS English ("the llama" for Ollama,
    /// "a goal" for AGOL); on real speech, none (the 2 correct ones were non-words).
    ///
    /// Works on the two texts: a word-level edit-distance alignment finds each span
    /// the rescorer rewrote. FluidAudio replaces a run of one or more words with ONE
    /// term token (boosted terms have no spaces), which fixes how a hunk is decided:
    ///   * one term: kept if the words it replaces include a non-word;
    ///   * as many terms as words: one word per term, so each pair is decided alone —
    ///     "Ezri, GOJSON," can repair both while "Ezri the llama" repairs one;
    ///   * several terms over more words: which words went to which term is not
    ///     recoverable from the text, so it is kept only if EVERY word is a non-word.
    ///     Deciding it as one hunk let "Dimaptic" carry "open a" → OpenAI through
    ///     (review, 2026-09-25);
    ///   * anything else (a bare insertion or deletion, more terms than words) is not
    ///     a shape the rescorer produces, so it is refused rather than guessed at.
    /// A refused span is restored verbatim; a kept one gets back the punctuation the
    /// rescorer drops ("to a goal." came back "to AGOL", "(Olama)" as "Ollama").
    public static func guardRepairs(
        raw: String, rescored: String, isWord: (String) -> Bool = isDictionaryWord
    ) -> (text: String, repairs: [BoostRepair]) {
        var out: [String] = []
        var repairs: [BoostRepair] = []
        for run in align(raw: raw, rescored: rescored) {
            guard case let .hunk(from, to) = run else {
                if case let .same(word) = run { out.append(word) }
                continue
            }
            if from.isEmpty || to.isEmpty || to.count > from.count {
                out += from
                repairs.append(BoostRepair(from: from.joined(separator: " "), to: to.joined(separator: " "), kept: false))
            } else if to.count == from.count {
                for (word, term) in zip(from, to) {
                    let kept = !isWord(word)
                    out.append(kept ? dress(term, lead: word, trail: word) : word)
                    repairs.append(BoostRepair(from: word, to: term, kept: kept))
                }
            } else {
                let kept = to.count == 1 ? from.contains { !isWord($0) } : from.allSatisfy { !isWord($0) }
                if kept {
                    var terms = to
                    if terms.count == 1 {
                        terms[0] = dress(terms[0], lead: from.first, trail: from.last)
                    } else {
                        terms[0] = dress(terms[0], lead: from.first, trail: nil)
                        terms[terms.count - 1] = dress(terms[terms.count - 1], lead: nil, trail: from.last)
                    }
                    out += terms
                } else {
                    out += from
                }
                repairs.append(BoostRepair(from: from.joined(separator: " "), to: to.joined(separator: " "), kept: kept))
            }
        }
        return (out.joined(separator: " "), repairs)
    }

    /// One aligned run: a word both texts share, or a hunk (words → replacement).
    public enum Aligned: Sendable, Equatable {
        case same(String)
        case hunk(from: [String], to: [String])
    }

    /// Word-level Levenshtein alignment, whitespace-insensitive. A substitution costs
    /// the same as an insert or a delete, so a word swapped for a term aligns as ONE
    /// substitution. The first cut used a longest-common-subsequence walk, which has no
    /// substitutions: "so Olama Ollama GOJSON" → "so Ollama Ollama GeoJSON" paired the
    /// new "Ollama" with the wrong copy and came out "so Olama Ollama Ollama GeoJSON".
    public static func align(raw: String, rescored: String) -> [Aligned] {
        let a = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        let b = rescored.split(whereSeparator: \.isWhitespace).map(String.init)
        let n = a.count, m = b.count
        // d[i][j] = edit distance between a[i...] and b[j...]
        var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][m] = n - i }
        for j in 0...m { d[n][j] = m - j }
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                d[i][j] = a[i] == b[j] ? d[i + 1][j + 1] : 1 + min(d[i + 1][j + 1], d[i + 1][j], d[i][j + 1])
            }
        }
        var runs: [Aligned] = []
        var from: [String] = [], to: [String] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                if !from.isEmpty || !to.isEmpty { runs.append(.hunk(from: from, to: to)); from = []; to = [] }
                runs.append(.same(a[i])); i += 1; j += 1
            } else if i < n, j < m, d[i][j] == 1 + d[i + 1][j + 1] {
                from.append(a[i]); to.append(b[j]); i += 1; j += 1
            } else if i < n, j == m || d[i][j] == 1 + d[i + 1][j] {
                from.append(a[i]); i += 1
            } else {
                to.append(b[j]); j += 1
            }
        }
        if !from.isEmpty || !to.isEmpty { runs.append(.hunk(from: from, to: to)) }
        return runs
    }

    /// Gives a kept term the punctuation the rescorer dropped: leading from `lead` (a
    /// bracket or quote), trailing from `trail`, unless the term already has its own.
    /// A punctuation-only word lends nothing.
    static func dress(_ term: String, lead: String?, trail: String?) -> String {
        func hasText(_ w: String) -> Bool { w.contains { $0.isLetter || $0.isNumber } }
        var t = term
        if let lead, hasText(lead) {
            let p = String(lead.prefix { $0.isPunctuation || $0.isSymbol })
            if !p.isEmpty, !(t.first.map { $0.isPunctuation || $0.isSymbol } ?? false) { t = p + t }
        }
        if let trail, hasText(trail) {
            let p = Glossary.splitTrailingPunctuation(trail).1
            if !p.isEmpty, Glossary.splitTrailingPunctuation(t).1.isEmpty { t += p }
        }
        return t
    }

    /// Whether the macOS spell checker knows this token as English. Checked lowercased
    /// (the checker waves ALL-CAPS and digit-bearing tokens through as written, so
    /// "GOJSON" would pass), and also as written when it is capitalised like a name
    /// ("Kevin", "Houston" fail lowercased). Also counted as words, never repaired: a
    /// token with no letters (numbers are content) and an ALL-CAPS acronym of up to 4
    /// letters — MCP, API, CEO — which the engine wrote that way because it heard
    /// letters, and which read as non-words lowercased ("ceo" does). Letters only:
    /// "SP32" stays repairable to ESP32.
    public static func isDictionaryWord(_ token: String) -> Bool {
        let core = token.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
        guard let first = core.first, core.contains(where: \.isLetter) else { return true }
        if core.count <= 4, core.allSatisfy({ $0.isLetter && $0.isUppercase }) { return true }
        if spelledCorrectly(core.lowercased()) { return true }
        return first.isUppercase && !core.dropFirst().contains(where: \.isUppercase) && spelledCorrectly(core)
    }

    // NSSpellChecker is shared process-wide and is reached here from the transcriber's
    // actor, not the main thread; one lock keeps two callers from overlapping in it.
    private static let spellLock = NSLock()

    static func spelledCorrectly(_ s: String) -> Bool {
        spellLock.lock()
        defer { spellLock.unlock() }
        return NSSpellChecker.shared.checkSpelling(
            of: s, startingAt: 0, language: "en", wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }

    static func normalize(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// 1 − Levenshtein / longer length.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        var d = Array(0...y.count)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            var prev = d[0]; d[0] = i
            for j in stride(from: 1, through: y.count, by: 1) {
                let tmp = d[j]
                d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1))
                prev = tmp
            }
        }
        return 1 - Double(d[y.count]) / Double(max(x.count, y.count))
    }

    /// Same floor as ParakeetTranscriber: a STOP-closed segment can be one 4,096-sample
    /// VAD frame; pad with silence rather than risk a short-input throw.
    public static func padded(_ samples: [Float]) -> [Float] {
        let floor = Int(AudioCapture.sampleRate * 0.5)
        return samples.count >= floor
            ? samples
            : samples + [Float](repeating: 0, count: floor - samples.count)
    }

    public func transcribe(samples: [Float]) async throws -> String {
        guard let manager else { throw TranscriberError.notPrepared("call prepare() first") }
        guard !samples.isEmpty else { return "" }
        let input = Self.padded(samples)
        do {
            guard let boosting else {
                return try await manager.transcribe(input).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // What UnifiedAsrManager does internally when boosting is configured on it
            // (same text, same timings, same audio), with the guard in between.
            let first = try await manager.transcribeWithTimings(input)
            let raw = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let out = await boosting.rescore(
                text: first.text, tokenTimings: first.tokenTimings, audioSamples: input)
            else { return raw }
            let guarded = Self.guardRepairs(raw: raw, rescored: out.text)
            // Terms only, never the words he said: the log stays transcript-free.
            let kept = guarded.repairs.filter(\.kept).map(\.to)
            let refused = guarded.repairs.filter { !$0.kept }.map(\.to)
            DiagnosticLog.write("vocabulary boost: kept \(kept.count) \(kept), refused \(refused.count) \(refused) (would have overwritten dictionary words)")
            return guarded.text
        } catch {
            throw TranscriberError.failed("\(error)")
        }
    }
}
