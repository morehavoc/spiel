import CoreML
import Foundation
import FluidAudio

/// The speech models Spiel Listen can run, and which one this iPhone gets (0.5.5).
///
/// Measured 2026-11-23/24 on Christopher's counting recording cut at 141 places
/// (`spiel-cli replay-sweep`) and on his real speech (Sep 23 Mac eval, word error rate):
///   standard  TDT v2 (English)           ~440 MB   0.87 errors/run   8.5 % WER
///   accurate  Unified EN 0.6B, int8      ~600 MB   0.61              6.7 %
///   accurateLarge  same, fp16 encoder   ~1.2 GB    0.62              6.7 %
/// TDT v3 (0.5.3 and before) was 3.96 and 11.2 %, and lost whole pieces.
///
/// The int8 Unified encoder does not load on an A16 (iPhone 14 Pro) on any compute
/// unit (FluidAudio #828), and no one publishes which other iPhone chips take it: the
/// only test is compiling it on the phone. So the app compiles a PROBE first: the real
/// int8 encoder graph with its int8 weights zeroed, shipped in the bundle as ~3.6 MB
/// (`Resources/UnifiedProbe`, rebuilt into a sparse file). Same graph, same quantised
/// layout, so the phone's compiler accepts or rejects it the way it would the real one.
///
/// Kept to the one "speech model" slot on purpose: speaker labels (0.6) will add their
/// own model slot beside this one, and `removeUnusedSpeechModels` never touches files
/// outside the speech models listed here.
enum SpeechModel: String, CaseIterable, Identifiable {
    case standard
    case accurate
    case accurateLarge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .accurate, .accurateLarge: return "Most accurate"
        }
    }

    var sizeText: String {
        switch self {
        case .standard: return "about 440 MB"
        case .accurate: return "about 600 MB"
        case .accurateLarge: return "about 1.2 GB"
        }
    }

    var note: String {
        switch self {
        case .standard: return "Good accuracy, smaller download."
        case .accurate, .accurateLarge: return "Best accuracy, bigger download."
        }
    }

    /// What the saved transcript's frontmatter says.
    var engineName: String {
        switch self {
        case .standard: return "parakeet-tdt-0.6b-v2"
        case .accurate: return "parakeet-unified-en-0.6b (int8)"
        case .accurateLarge: return "parakeet-unified-en-0.6b (fp16)"
        }
    }

    var isDownloaded: Bool {
        switch self {
        case .standard: return ParakeetTranscriber.isDownloaded(version: .v2)
        case .accurate: return ParakeetUnifiedTranscriber.isDownloaded(precision: .int8)
        case .accurateLarge: return ParakeetUnifiedTranscriber.isDownloaded(precision: .fp16)
        }
    }

    func makeTranscriber(progress: ModelProgressHandler?) -> any Transcriber {
        switch self {
        case .standard: return ParakeetTranscriber(version: .v2, progress: progress)
        case .accurate: return ParakeetUnifiedTranscriber(boost: false, precision: .int8, progress: progress)
        case .accurateLarge: return ParakeetUnifiedTranscriber(boost: false, precision: .fp16, progress: progress)
        }
    }

    // MARK: - Choice

    private static let choiceKey = "SpeechModelChoice"
    private static let probeKey = "UnifiedInt8Probe"  // "<iOS version>|pass" or "|fail"

    /// The model the user (or the automatic pick) settled on; nil before the first pick.
    static var saved: SpeechModel? {
        get { UserDefaults.standard.string(forKey: choiceKey).flatMap(SpeechModel.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: choiceKey) }
    }

    /// A model already on the phone from an earlier build counts as the choice, so an
    /// update never forces a new download (build 118 put the fp16 model on phones).
    static func adoptDownloaded() -> SpeechModel? {
        if let s = saved { return s }
        for m in [SpeechModel.accurate, .accurateLarge, .standard] where m.isDownloaded {
            saved = m
            DiagnosticLog.write("speech model: kept the \(m.engineName) already on this iPhone")
            return m
        }
        return nil
    }

    /// The probe's answer for this iOS version, if it has run.
    static var int8Supported: Bool? {
        guard let v = UserDefaults.standard.string(forKey: probeKey) else { return nil }
        let parts = v.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, String(parts[0]) == osVersion else { return nil }
        return parts[1] == "pass"
    }

    static func recordInt8(_ ok: Bool) {
        UserDefaults.standard.set("\(osVersion)|\(ok ? "pass" : "fail")", forKey: probeKey)
    }

    private static var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }

    /// The models offered on this iPhone: Standard plus the one "Most accurate" it can run.
    static func offered(int8: Bool) -> [SpeechModel] { [.standard, int8 ? .accurate : .accurateLarge] }

    /// The automatic pick: most accurate when the ~600 MB version runs here, else Standard
    /// (the 1.2 GB version is an upgrade the user chooses, never a default).
    static func recommended(int8: Bool) -> SpeechModel { int8 ? .accurate : .standard }

    // MARK: - Probe

    /// Compiles the zero-weight int8 encoder on this phone. Cached per iOS version (a
    /// new iOS can change the compiler). Never throws: a probe that cannot run is a fail.
    static func probeInt8() async -> Bool {
        #if DEBUG
        if let forced = ProcessInfo.processInfo.environment["SPIEL_FORCE_PROBE"] {
            recordInt8(forced == "pass"); return forced == "pass"
        }
        #endif
        if let known = int8Supported { return known }
        let started = Date()
        let ok: Bool
        do {
            let url = try buildProbe()
            defer { try? FileManager.default.removeItem(at: url) }
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .cpuAndNeuralEngine
            _ = try await MLModel.load(contentsOf: url, configuration: cfg)
            ok = true
            DiagnosticLog.write("int8 probe: compiled on this iPhone in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        } catch {
            ok = false
            DiagnosticLog.write("int8 probe: refused after \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(error)")
        }
        recordInt8(ok)
        return ok
    }

    /// Rebuilds the probe `.mlmodelc` in Caches from the bundle: weight.bin is the
    /// original size with the int8 data left as zeros (a sparse file, ~2.5 MB on disk).
    static func buildProbe() throws -> URL {
        guard let src = Bundle.main.url(forResource: "UnifiedProbe", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let fm = FileManager.default
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("unified-int8-probe.mlmodelc", isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir.appendingPathComponent("weights"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("analytics"), withIntermediateDirectories: true)
        try fm.copyItem(at: src.appendingPathComponent("model.mil"), to: dir.appendingPathComponent("model.mil"))
        try fm.copyItem(at: src.appendingPathComponent("coremldata.bin"), to: dir.appendingPathComponent("coremldata.bin"))
        try fm.copyItem(at: src.appendingPathComponent("analytics-coremldata.bin"),
                        to: dir.appendingPathComponent("analytics/coremldata.bin"))
        try writeWeights(segments: src.appendingPathComponent("weight.segments"),
                         to: dir.appendingPathComponent("weights/weight.bin"))
        return dir
    }

    /// Format (tools: native/ios/scripts/make-unified-probe.py): "SPCN", u64 total size,
    /// u32 count, then count × (u64 offset, u64 length, bytes).
    static func writeWeights(segments: URL, to out: URL) throws {
        let d = try Data(contentsOf: segments)
        func u64(_ at: Int) -> UInt64 { d.subdata(in: at..<at + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) } }
        func u32(_ at: Int) -> UInt32 { d.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        guard d.count >= 16, d.prefix(4) == Data("SPCN".utf8) else { throw CocoaError(.fileReadCorruptFile) }
        let total = u64(4), count = Int(u32(12))
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let h = try FileHandle(forWritingTo: out)
        defer { try? h.close() }
        try h.truncate(atOffset: total)
        var p = 16
        for _ in 0..<count {
            let off = u64(p), len = Int(u64(p + 8)); p += 16
            guard p + len <= d.count else { throw CocoaError(.fileReadCorruptFile) }
            try h.seek(toOffset: off)
            try h.write(contentsOf: d.subdata(in: p..<p + len))
            p += len
        }
    }

    // MARK: - Cleanup

    /// After `keep` has loaded: deletes the other speech models (and 0.5.3's TDT v3).
    /// Only the folders and encoder files of the models above; anything else in the
    /// FluidAudio folder (the VAD, a future speaker model) is left alone.
    static func removeUnusedSpeechModels(keep: SpeechModel) {
        let fm = FileManager.default
        var gone: [URL] = [AsrModels.defaultCacheDirectory(for: .v3)]
        if keep != .standard { gone.append(AsrModels.defaultCacheDirectory(for: .v2)) }
        let unified = ParakeetUnifiedTranscriber.cacheDirectory
        switch keep {
        case .standard: gone.append(unified)
        case .accurate: gone.append(unified.appendingPathComponent(ModelNames.ParakeetUnified.offlineEncoderFile(precision: .fp16)))
        case .accurateLarge: gone.append(unified.appendingPathComponent(ModelNames.ParakeetUnified.offlineEncoderFile(precision: .int8)))
        }
        for url in gone where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
                DiagnosticLog.write("removed an unused speech model: \(url.lastPathComponent)")
            } catch {
                DiagnosticLog.write("could not remove \(url.lastPathComponent): \(error)")
            }
        }
    }
}
