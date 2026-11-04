import AVFoundation
import Foundation
import FluidAudio
import SwiftUI
import UIKit

/// One Listen session on the iPhone: mic → `DictationSession` (the Mac's VAD,
/// segmenting and ordering, unchanged) → `TranscriptDocument` → autosaved
/// Markdown in Documents/Spiel/Transcripts.
@MainActor
final class ListenModel: ObservableObject {
    enum Phase: Equatable {
        /// The speech model is not on this iPhone yet; waiting for the user to start the download.
        case needsDownload
        case loading(String)
        case ready
        case recording
        case paused
        /// An audio file is going through the session in place of the mic.
        case transcribing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading("Starting…")
    @Published private(set) var doc = TranscriptDocument()
    @Published var title = "" { didSet { if oldValue != title, startedAt != nil { save() } } }
    @Published private(set) var startedAt: Date?
    @Published private(set) var fileURL: URL?
    @Published private(set) var lastError: String?
    /// Bumped on every document change, so the view can follow the newest line.
    @Published private(set) var revision = 0
    /// Mic loudness 0…1, ~12 updates a second, for the live waveform.
    @Published private(set) var level: Float = 0
    @Published private(set) var location: String?
    /// The kept recording, when this meeting keeps audio.
    @Published private(set) var audioURL: URL?
    /// Where the model load is, for the progress bar: step 1 = download (has a fraction),
    /// step 2 = preparing for the Neural Engine (no fraction exists for it; shown indeterminate).
    struct LoadStep: Equatable { var step: Int; var fraction: Double?; var since: Date }
    @Published private(set) var loadStep: LoadStep?
    /// 0…1 through the audio file; nil while the file is still being copied in.
    @Published private(set) var fileProgress: Double?

    private var session: DictationSession?
    private let capture = AudioCapture()
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0
    private var endedAt: Date?
    private var autosave: Timer?
    private var consecutiveFailures = 0
    private var observers: [NSObjectProtocol] = []
    private var interrupted = false
    private var recorder: AudioRecorder?
    private let meter = LevelMeter()
    private let locator = MeetingContext()
    private var sourceFile: String?
    private var fileSeconds: Double?
    private var fileTask: Task<Void, Never>?

    var isActive: Bool { phase == .recording || phase == .paused }

    init() {
        observeAudioSession()
        if ParakeetTranscriber.isDownloaded(version: .v3) {
            Task { await loadEngine() }
        } else {
            phase = .needsDownload
            #if DEBUG
            if ProcessInfo.processInfo.environment["SPIEL_AUTODOWNLOAD"] == "1" { downloadModel() }
            #endif
        }
    }

    /// Starts (or retries) loading the speech model, downloading it if needed.
    func downloadModel() {
        switch phase {
        case .needsDownload, .failed: break
        default: return
        }
        phase = .loading("Starting…")
        Task { await loadEngine() }
    }

    // MARK: - Engine

    private func loadEngine() async {
        let transcriber = ParakeetTranscriber(version: .v3) { p in
            let text: String
            var step = 0
            switch p.phase {
            case .listing: text = "Finding the speech model…"
            case .downloading:
                text = "Downloading the speech model (about 500 MB, once)"; step = 1
            case .compiling:
                text = "Preparing the speech model for the Neural Engine. This happens once and can take a few minutes."; step = 2
            }
            let fraction = p.downloadFraction
            DispatchQueue.main.async { MainActor.assumeIsolated { self.noteLoading(text, step: step, fraction: fraction) } }
        }
        let s = DictationSession(transcriber: transcriber)
        do {
            try await s.prepare()
        } catch {
            loadStep = nil
            phase = .failed("The speech model did not load: \(error)")
            DiagnosticLog.write("engine load failed: \(error)")
            return
        }
        // DispatchQueue.main.async is FIFO; a Task per event is not, and events
        // landing out of order would reorder the transcript.
        await s.setEventHandler { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
        }
        session = s
        loadStep = nil
        Self.excludeModelsFromBackup()
        phase = .ready
        #if DEBUG
        if ProcessInfo.processInfo.environment["SPIEL_AUTOSTART"] == "1" {
            if let path = ProcessInfo.processInfo.environment["SPIEL_AUTOFILE"] {
                transcribeFile(URL(fileURLWithPath: path))
                return
            }
            start(title: "Design review", location: "Workshop, Portland", keepAudio: true)
            if let secs = Double(ProcessInfo.processInfo.environment["SPIEL_AUTOSTOP"] ?? "") {
                DispatchQueue.main.asyncAfter(deadline: .now() + secs) { MainActor.assumeIsolated { self.stop() } }
            }
        }
        #endif
    }

    /// The speech model is re-downloadable, so it stays out of iCloud/device backups
    /// (Apple's data-storage rule; it would also add ~500 MB to every backup).
    /// Transcripts and kept audio live in Documents and ARE backed up.
    private static func excludeModelsFromBackup() {
        var dir = AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do { try dir.setResourceValues(values) } catch { DiagnosticLog.write("could not exclude models from backup: \(error)") }
    }

    private func noteLoading(_ text: String, step: Int = 0, fraction: Double? = nil) {
        guard case .loading = phase else { return }
        phase = .loading(text)
        if step == 0 { return }
        if loadStep?.step == step {
            loadStep?.fraction = fraction
        } else {
            loadStep = LoadStep(step: step, fraction: fraction, since: Date())
        }
    }

    // MARK: - Controls

    /// Looks up where the phone is (Apple geocoding) once the meeting has started, and
    /// writes the place into the transcript when it arrives. Only called when the user
    /// turned on Add location and the calendar event had no location of its own.
    func addCurrentLocation() {
        locator.onPlace = { [weak self] place in
            guard let self, self.isActive, self.location == nil else { return }
            self.location = place
            self.save()
        }
        locator.locate()
    }

    func start(title: String, location: String?, keepAudio: Bool) {
        guard phase == .ready, let session else { return }
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                lastError = "Microphone access is off. Settings → Spiel Listen → Microphone."
                return
            }
            await session.setGlossary(Glossary.load())
            await session.reset()
            doc = TranscriptDocument()
            revision += 1
            let started = Date()
            startedAt = started
            endedAt = nil
            fileURL = nil
            self.title = title.isEmpty ? Self.dateTitle(started) : title
            self.location = location
            sourceFile = nil
            fileSeconds = nil
            audioURL = nil
            recorder = nil
            if keepAudio {
                // Named once at start and never renamed, so the transcript's `audio:`
                // line keeps pointing at it even if the title is edited later.
                let name = String(TranscriptStore.fileName(title: self.title, startedAt: started).dropLast(3)) + ".m4a"
                let url = TranscriptStore.defaultFolder.appendingPathComponent(name)
                do {
                    recorder = try AudioRecorder(url: url)
                    audioURL = url
                } catch {
                    lastError = "Audio won't be kept: \(error.localizedDescription). The transcript still works."
                }
            }
            pausedTotal = 0
            consecutiveFailures = 0
            lastError = nil
            guard openMic(into: session) else { return }
            phase = .recording
            UIApplication.shared.isIdleTimerDisabled = true
            autosave = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                MainActor.assumeIsolated { self.save() }
            }
            save()
        }
    }

    func pause() {
        guard phase == .recording else { return }
        capture.stop()
        pausedAt = Date()
        phase = .paused
        level = 0
    }

    func resume() {
        guard phase == .paused, let session else { return }
        closePause()
        if openMic(into: session) { phase = .recording }
    }

    func stop() {
        guard isActive, let session else { return }
        if phase == .paused { closePause() }
        capture.stop()
        phase = .ready
        autosave?.invalidate(); autosave = nil
        UIApplication.shared.isIdleTimerDisabled = false
        meter.reset(); level = 0
        let rec = recorder
        recorder = nil
        Task {
            await Task.detached { rec?.finish() }.value
            if let e = rec?.error { lastError = "The recording stopped early: \(e)" }
            let report = await session.finishWithReport()
            endedAt = report.endedAt
            if !report.errors.isEmpty { DiagnosticLog.write("listen ended with errors: \(report.diagnosis)") }
            save()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            runStopShortcut()
        }
    }

    // MARK: - Transcribe an audio file

    /// Same session, document and saved transcript as a meeting; only the samples differ.
    /// The picked file is copied in first: Files can hand over an iCloud file that is
    /// not on the phone yet, and the coordinated copy is what fetches it.
    func transcribeFile(_ picked: URL) {
        guard phase == .ready, let session else { return }
        phase = .transcribing
        fileProgress = nil
        doc = TranscriptDocument()
        revision += 1
        let started = Date()
        startedAt = started
        endedAt = nil
        fileURL = nil
        title = picked.deletingPathExtension().lastPathComponent
        location = nil
        audioURL = nil
        recorder = nil
        sourceFile = picked.lastPathComponent
        fileSeconds = nil
        consecutiveFailures = 0
        lastError = nil
        UIApplication.shared.isIdleTimerDisabled = true
        fileTask = Task {
            var copy: URL?
            defer { if let copy { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) } }
            do {
                let local = try await Task.detached { try Self.localCopy(of: picked) }.value
                copy = local
                try Task.checkCancellation()
                await session.setGlossary(Glossary.load())
                await session.reset()
                fileProgress = 0
                let report = try await FileTranscriber.feed(local, session: session) { done, total in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.fileSeconds = total > 0 ? total : done
                            self.fileProgress = total > 0 ? min(done / total, 1) : nil
                        }
                    }
                }
                fileSeconds = report.audioSeconds
                endedAt = report.endedAt
                if !report.errors.isEmpty { DiagnosticLog.write("file ended with errors: \(report.diagnosis)") }
                if doc.isEmpty {
                    lastError = "No speech found: " + FileTranscriber.fileDiagnosis(
                        audioSeconds: report.audioSeconds, peak: report.peak, segments: report.segments, errors: report.errors)
                } else {
                    save()
                }
            } catch is CancellationError {
                await session.reset()
                // A partial transcript would read as a whole one later.
                if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
                fileURL = nil
                doc = TranscriptDocument()
                startedAt = nil
                sourceFile = nil
                DiagnosticLog.write("file transcription cancelled")
            } catch {
                await session.reset()
                DiagnosticLog.write("file transcription failed: \(error)")
                lastError = "Could not finish that file: \(error)"
                endedAt = Date()
                if !doc.isEmpty { save() }
            }
            UIApplication.shared.isIdleTimerDisabled = false
            fileProgress = nil
            fileTask = nil
            phase = .ready
        }
    }

    func cancelFile() { fileTask?.cancel() }

    /// `nonisolated`: the copy can be slow and must not run on the main thread.
    private nonisolated static func localCopy(of url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The name is kept: AVFoundation picks its parser by extension.
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { source in
            do { try FileManager.default.copyItem(at: source, to: dest) } catch { copyError = error }
        }
        if let e = coordinatorError ?? copyError {
            try? FileManager.default.removeItem(at: dir)
            throw e
        }
        return dest
    }

    // MARK: - Shortcut when Listen stops

    static let stopShortcutKey = "ListenStopShortcut"
    /// The Shortcut run with the transcript every time Listen stops; nil = none.
    static var stopShortcut: String? {
        get {
            let v = UserDefaults.standard.string(forKey: stopShortcutKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (v?.isEmpty ?? true) ? nil : v
        }
        set {
            if let v = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                UserDefaults.standard.set(v, forKey: stopShortcutKey)
            } else {
                UserDefaults.standard.removeObject(forKey: stopShortcutKey)
            }
        }
    }

    /// iOS lets an app run a Shortcut only by opening the Shortcuts app with a URL, so
    /// this switches to Shortcuts; x-success brings the user back to Spiel when it ends.
    /// A transcript that fits in the URL is passed as the Shortcut's input text; a longer
    /// one is not passed at all (never via the clipboard), and the Shortcut reads it with
    /// the "Get Latest Spiel Transcript" action (GetLatestTranscriptIntent), which works
    /// at any length.
    private func runStopShortcut() {
        guard let name = Self.stopShortcut else { return }
        guard let fileURL, let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            lastError = "\(name) did not run: the transcript was not saved."
            return
        }
        guard UIApplication.shared.applicationState == .active else {
            DiagnosticLog.write("stop shortcut skipped: Spiel was not in the foreground")
            lastError = "\(name) did not run because Spiel was in the background when Listen stopped."
            return
        }
        guard let url = Self.shortcutURL(name: name, text: text) else { return }
        DiagnosticLog.write("stop shortcut running (\(text.utf8.count) bytes, \(text.utf8.count <= Self.maxURLText ? "passed as input" : "too long to pass; use Get Latest Spiel Transcript"))")
        UIApplication.shared.open(url) { [weak self] ok in
            if !ok { self?.lastError = "Could not open Shortcuts to run \(name)." }
        }
    }

    /// Characters other than these are percent-encoded; '+', '&' and '=' must not survive raw.
    private static let queryAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    static let maxURLText = 100_000

    static func shortcutURL(name: String, text: String) -> URL? {
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? "" }
        var q = "name=\(enc(name))"
        if text.utf8.count <= maxURLText {
            q += "&input=text&text=\(enc(text))"
        }
        q += "&x-success=\(enc("spiellisten://done"))&x-cancel=\(enc("spiellisten://done"))&x-error=\(enc("spiellisten://done"))"
        return URL(string: "shortcuts://x-callback-url/run-shortcut?" + q)
    }

    private func openMic(into session: DictationSession) -> Bool {
        let sink = session.sink
        let rec = recorder
        let meter = self.meter
        do {
            try capture.start { samples in
                sink.submit(samples)
                rec?.append(samples)
                if let l = meter.feed(samples) {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.level = l } }
                }
            }
            return true
        } catch {
            lastError = "\(error)"
            DiagnosticLog.write("mic start failed: \(error)")
            if phase == .recording || phase == .paused { phase = .paused }
            return false
        }
    }

    private func closePause() {
        guard let session, let pausedAt else { return }
        let span = Date().timeIntervalSince(pausedAt)
        self.pausedAt = nil
        pausedTotal += span
        Task {
            let at = await session.audioSeconds
            await session.notePause(seconds: span)
            doc.notePause(seconds: span, atOffset: at)
            revision += 1
            save()
        }
    }

    // MARK: - Events

    private func handle(_ event: DictationSession.Event) {
        switch event {
        case .speechStarted, .segmentCaptured:
            break
        case .textReleased(let t, let at, let gap, _):
            let before = doc.paragraphs.count
            doc.append(text: t, startOffset: at, gapBefore: gap)
            consecutiveFailures = 0
            revision += 1
            if doc.paragraphs.count != before || (!isActive && phase != .transcribing) { save() }
        case .error(let e, let at, let secs):
            DiagnosticLog.write("listen segment error: \(e)")
            doc.noteMissed(seconds: secs, atOffset: at)
            revision += 1
            consecutiveFailures += 1
            if consecutiveFailures >= 3 {
                lastError = "Speech recognition failed 3 times in a row. Stop and start again; the transcript so far is saved."
            }
            save()
        }
    }

    // MARK: - Saving

    func save() {
        guard let startedAt else { return }
        let url = TranscriptStore.url(for: title, startedAt: startedAt, current: fileURL)
        let fm = TranscriptDocument.Frontmatter(
            title: title, startedAt: startedAt, endedAt: endedAt ?? Date(),
            version: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "dev") (iPhone)",
            inputDevice: AudioCapture.currentInputName, engine: "parakeet-tdt-0.6b-v3",
            location: location, audio: audioURL?.lastPathComponent, sourceFile: sourceFile, fileSeconds: fileSeconds)
        do {
            try TranscriptStore.save(doc.render(frontmatter: fm), to: url, replacing: fileURL)
            fileURL = url
        } catch {
            lastError = "Autosave failed: \(error). Copy the text before closing."
            DiagnosticLog.write("autosave failed: \(error)")
        }
    }

    static func dateTitle(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    /// Elapsed wall time of the session, pauses included.
    func elapsed(now: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return (endedAt ?? now).timeIntervalSince(startedAt)
    }

    // MARK: - Interruptions

    /// A phone call or Siri takes the mic: treat it as a pause and pick up when
    /// iOS hands it back. A route change (AirPods in/out) restarts capture on the
    /// new input and marks it in the transcript.
    private func observeAudioSession() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { n in
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let opts = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                if raw == AVAudioSession.InterruptionType.began.rawValue, self.phase == .recording {
                    self.interrupted = true
                    self.pause()
                } else if raw == AVAudioSession.InterruptionType.ended.rawValue, self.interrupted {
                    // Resume even without `.shouldResume`: he pressed Record, not
                    // the interruption, and a missed hour is worse than a reopened mic.
                    _ = opts
                    self.interrupted = false
                    self.resume()
                }
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { n in
            let reason = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                guard self.phase == .recording, let session = self.session,
                      reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
                        || reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                self.capture.stop()
                guard self.openMic(into: session) else { return }
                let name = AudioCapture.currentInputName
                Task {
                    let at = await session.audioSeconds
                    await session.noteCaptureRestart()
                    self.doc.noteCaptureRestart(device: name, atOffset: at)
                    self.revision += 1
                }
            }
        })
    }
}


/// RMS of the incoming 16 kHz samples, reported every ~80 ms, scaled so speech
/// at arm's length fills most of the meter. Called on the audio thread.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var sum: Float = 0
    private var count = 0
    func feed(_ s: [Float]) -> Float? {
        lock.lock(); defer { lock.unlock() }
        for x in s { sum += x * x }
        count += s.count
        guard count >= 1280 else { return nil }
        let rms = (sum / Float(count)).squareRoot()
        sum = 0; count = 0
        // ~-50 dBFS → 0, ~-10 dBFS → 1
        let db = 20 * log10(max(rms, 1e-6))
        return min(1, max(0, (db + 50) / 40))
    }
    func reset() { lock.lock(); sum = 0; count = 0; lock.unlock() }
}
