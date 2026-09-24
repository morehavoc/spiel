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
    // here leaves plain transcription running.
    private let boostEnabled: Bool
    private var ctcModels: CtcModels?
    private var ctcTokenizer: CtcTokenizer?
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
    static let minSimilarity: Float = 0.80
    static let neighbourSimilarity: Double = 0.9
    static let rescorerConfig = VocabularyRescorer.Config(
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
        guard boostEnabled, let manager, entries != boostedVocabulary else { return }
        do {
            if ctcModels == nil {
                ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
                ctcTokenizer = try await CtcTokenizer.load(
                    from: CtcModels.defaultCacheDirectory(for: .ctc110m))
            }
            guard let ctcModels, let ctcTokenizer else { return }
            let boostable = entries.keys.sorted().filter { Self.isBoostable($0) }
            let terms: [CustomVocabularyTerm] = boostable.compactMap { canonical in
                let ids = ctcTokenizer.encode(canonical)
                guard !ids.isEmpty else { return nil }
                let aliases = entries[canonical] ?? []
                return CustomVocabularyTerm(
                    text: canonical, aliases: aliases.isEmpty ? nil : aliases, ctcTokenIds: ids)
            }
            try await manager.configureVocabularyBoosting(
                vocabulary: CustomVocabularyContext(
                    terms: terms,
                    minSimilarity: Self.minSimilarity),
                ctcModels: ctcModels,
                config: Self.rescorerConfig)
            boostedVocabulary = entries
            boostTermCount = terms.count
            boostError = nil
            DiagnosticLog.write("vocabulary boost configured: \(terms.count) of \(entries.count) terms (\(entries.count - boostable.count) left to the text glossary as near-English)")
        } catch {
            boostError = "\(error)"
            DiagnosticLog.write("vocabulary boost unavailable (plain transcription continues): \(error)")
        }
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
        let checker = NSSpellChecker.shared
        let lower = term.lowercased()
        let range = NSRange(location: 0, length: (lower as NSString).length)
        let miss = checker.checkSpelling(of: lower, startingAt: 0, language: "en", wrap: false,
                                         inSpellDocumentWithTag: 0, wordCount: nil)
        if miss.location == NSNotFound { return false }  // it is an English word (or words)
        let guesses = checker.guesses(forWordRange: range, in: lower, language: "en",
                                      inSpellDocumentWithTag: 0) ?? []
        return !guesses.contains { Self.similarity(Self.normalize($0), norm) >= neighbourSimilarity }
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

    public func transcribe(samples: [Float]) async throws -> String {
        guard let manager else { throw TranscriberError.notPrepared("call prepare() first") }
        guard !samples.isEmpty else { return "" }
        // Same floor as ParakeetTranscriber: a STOP-closed segment can be one
        // 4,096-sample VAD frame; pad with silence rather than risk a short-input throw.
        let floor = Int(AudioCapture.sampleRate * 0.5)
        let input = samples.count >= floor
            ? samples
            : samples + [Float](repeating: 0, count: floor - samples.count)
        do {
            return try await manager.transcribe(input).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw TranscriberError.failed("\(error)")
        }
    }
}
