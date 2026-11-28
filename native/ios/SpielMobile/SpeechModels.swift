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
/// Which iPhones run the int8 Unified encoder is not published (FluidAudio #828 says it
/// fails on an A16; it loaded on his iPhone 14 Pro (A16) and iPhone Duo in Nov 2026). So
/// every phone gets it first; if it will not load, the app records that (per iOS version),
/// removes it and falls back to Standard, and Settings then offers the fp16 1.2 GB version.
/// 0.5.5-0.5.6 compiled a zero-weight probe first; it cost 16-46 s on first launch and was
/// dropped in 0.5.7 (his call, 2026-11-27).
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
    /// `int8` nil = not tried on this iPhone yet: offered as the ~600 MB version (a failed
    /// load falls back to Standard and records false, and then the 1.2 GB one is offered).
    static func offered(int8: Bool?) -> [SpeechModel] { [.standard, int8 == false ? .accurateLarge : .accurate] }

    /// The automatic pick: most accurate when the ~600 MB version runs here, else Standard
    /// (the 1.2 GB version is an upgrade the user chooses, never a default).
    static func recommended(int8: Bool?) -> SpeechModel { int8 == false ? .standard : .accurate }

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
