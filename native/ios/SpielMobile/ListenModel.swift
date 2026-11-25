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
    /// The speech model this iPhone runs (0.5.5): picked automatically, changeable in Settings.
    @Published private(set) var speechModel: SpeechModel = SpeechModel.saved ?? .standard
    /// The probe's answer: nil until it has run on this iOS version.
    @Published private(set) var int8Supported: Bool? = SpeechModel.int8Supported
    /// A switch in Settings is downloading or loading.
    @Published private(set) var switchingModel = false
    /// 0.5: the model loads in the background; a meeting can start before it is ready.
    /// nil = ready (or not downloaded yet); otherwise the line Home and the meeting show.
    @Published private(set) var preparing: String?
    /// The model load failed after the download (Home offers Try again).
    @Published private(set) var engineError: String?
    /// True from the moment the model is ready until the audio queued before it is replayed.
    @Published private(set) var catchingUp = false
    /// Stop was pressed before the model was ready; the meeting finishes once it catches up.
    @Published private(set) var finishing = false
    /// Bumped each time a meeting or file is saved and closed, so Home reloads its list.
    @Published private(set) var savedCount = 0
    /// One-line note for Home after a meeting closes ("Saved", or what went wrong).
    @Published var homeNote: String?
    /// A transcribed file is finished and on screen for review; Save or Delete closes it.
    @Published private(set) var reviewing = false
    private let feed = PendingFeed()
    private let health = MeetingHealth()  // TEMPORARY (0.5.3)
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
    var engineReady: Bool { session != nil }
    /// A meeting or file is open: the meeting screen is shown over Home.
    var inSession: Bool { startedAt != nil }

    init() {
        // The iPhone log holds events and counts, never transcript text, so it is
        // always on; Send Diagnostics (gear menu on Home) shares it.
        DiagnosticLog.setEnabled(true, persist: false)
        let adopted = SpeechModel.adoptDownloaded()
        if let adopted { speechModel = adopted }
        DiagnosticLog.write("app launched: build \(Self.currentBuild), speech model: \(adopted?.engineName ?? "not chosen yet"), on the phone: \(adopted?.isDownloaded ?? false)")
        observeAudioSession()
        if let adopted, adopted.isDownloaded {
            phase = .ready
            preparing = Self.preparingText()
            Task { await loadEngine() }
            #if DEBUG
            let env = ProcessInfo.processInfo.environment
            if env["SPIEL_START_EARLY"] == "1" {
                start(title: "Early start test", location: nil, keepAudio: false)
                if let secs = Double(env["SPIEL_AUTOSTOP"] ?? "") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + secs) { MainActor.assumeIsolated { self.stop() } }
                }
            }
            #endif
        } else if adopted != nil {
            phase = .needsDownload
            autoDownloadForTests()
        } else {
            // First launch (or 0.5.3's v3 only): check what this iPhone can run, then offer that download.
            phase = .loading("Checking this iPhone…")
            Task { await pickAutomatically() }
        }
    }

    private func autoDownloadForTests() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SPIEL_AUTODOWNLOAD"] == "1" { downloadModel() }
        #endif
    }

    /// The automatic pick: the most accurate model this phone can run at ~600 MB, else Standard.
    private func pickAutomatically() async {
        let ok = await SpeechModel.probeInt8()
        int8Supported = ok
        let pick = SpeechModel.recommended(int8: ok)
        SpeechModel.saved = pick
        speechModel = pick
        DiagnosticLog.write("speech model picked automatically: \(pick.engineName) (int8 probe \(ok ? "passed" : "failed"))")
        phase = .needsDownload
        autoDownloadForTests()
    }

    /// Runs the probe for Settings if it has not run on this iOS version yet.
    func checkHardware() async {
        guard int8Supported == nil else { return }
        int8Supported = await SpeechModel.probeInt8()
    }

    /// Settings: switch to another speech model. The current one keeps its files until
    /// the new one has loaded; if the new one fails, Spiel goes back to the old one.
    func switchModel(to new: SpeechModel) {
        guard new != speechModel, !inSession, !switchingModel else { return }
        let previous = speechModel
        let previousReady = session != nil
        DiagnosticLog.write("speech model switch: \(previous.engineName) -> \(new.engineName)")
        switchingModel = true
        speechModel = new
        SpeechModel.saved = new
        session = nil
        engineError = nil
        phase = .loading("Starting…")
        Task {
            let ok = await loadEngine()
            if !ok, previousReady, previous.isDownloaded {
                DiagnosticLog.write("speech model switch failed; back to \(previous.engineName)")
                speechModel = previous
                SpeechModel.saved = previous
                homeNote = "\(new.title) didn't load, so Spiel is back on \(previous.title)."
                phase = .loading("Starting…")
                await loadEngine()
            }
            switchingModel = false
        }
    }

    /// Starts (or retries) loading the speech model, downloading it if needed.
    func downloadModel() {
        if engineError != nil, session == nil {
            engineError = nil
            preparing = Self.preparingText()
            Task { await loadEngine() }
            return
        }
        switch phase {
        case .needsDownload, .failed: break
        default: return
        }
        phase = .loading("Starting…")
        Task { await loadEngine() }
    }

    private static let lastLoadedBuildKey = "ModelLoadedForBuild"
    private static var currentBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }
    /// After an update iOS re-prepares the model for the Neural Engine, which takes minutes, not seconds.
    private static func preparingText() -> String {
        UserDefaults.standard.string(forKey: lastLoadedBuildKey) == currentBuild
            ? "Preparing the speech model…"
            : "Getting ready after the update. This one can take a few minutes."
    }

    // MARK: - Engine

    @discardableResult
    private func loadEngine() async -> Bool {
        let loadStarted = Date()
        let choice = speechModel
        let size = choice.sizeText
        let transcriber = choice.makeTranscriber { p in
            var text: String
            var step = 0
            switch p.phase {
            case .listing: text = "Finding the speech model…"
            case .downloading:
                text = "Downloading the speech model (\(size), once)"; step = 1
                // FluidAudio reports no compiling phase for these models (the compile runs
                // inside loadWithRecovery with no handler), so 100 % downloaded IS step 2.
                if (p.downloadFraction ?? 0) >= 0.999 {
                    text = "Preparing the speech model for the Neural Engine. The first time can take a few minutes."; step = 2
                }
            case .compiling:
                text = "Preparing the speech model for the Neural Engine. The first time can take a few minutes."; step = 2
            }
            let fraction = p.downloadFraction
            DispatchQueue.main.async { MainActor.assumeIsolated { self.noteLoading(text, step: step, fraction: fraction) } }
        }
        let s = DictationSession(transcriber: transcriber)
        do {
            #if DEBUG
            // Simulates the slow Neural Engine load the simulator never has.
            if let d = Double(ProcessInfo.processInfo.environment["SPIEL_SLOW_LOAD"] ?? "") {
                try await Task.sleep(for: .seconds(d))
            }
            #endif
            try await s.prepare()
            #if DEBUG
            if choice == .accurate, ProcessInfo.processInfo.environment["SPIEL_FAIL_INT8"] == "1" {
                throw TranscriberError.unavailable("simulated int8 compile failure")
            }
            #endif
        } catch {
            loadStep = nil
            DiagnosticLog.write("engine load failed after \(Int(Date().timeIntervalSince(loadStarted))) s (\(choice.engineName)): \(error)")
            preparing = nil
            // The probe passed but the real ~600 MB model will not compile here: remember
            // that, and fall back to Standard (never to another 600 MB try).
            if choice == .accurate, choice.isDownloaded, !inSession {
                SpeechModel.recordInt8(false)
                int8Supported = false
                SpeechModel.saved = .standard
                speechModel = .standard
                SpeechModel.removeUnusedSpeechModels(keep: .standard)
                homeNote = "This iPhone can't run the 600 MB model, so Spiel is using Standard."
                DiagnosticLog.write("int8 model failed to load after a passing probe; switched to Standard")
                phase = .loading("Starting…")
                return await loadEngine()
            }
            if case .loading = phase {
                phase = .failed("The speech model did not load: \(error)")
            } else {
                engineError = "The speech model did not load: \(error)"
                if inSession { lastError = "The speech model did not load, so this meeting has no transcript yet." + (audioURL != nil ? " The audio is being kept." : "") }
                if finishing { closeAfterStop(nil) }
            }
            return false
        }
        DiagnosticLog.write("engine loaded in \(String(format: "%.1f", Date().timeIntervalSince(loadStarted))) s (build \(Self.currentBuild))")
        UserDefaults.standard.set(Self.currentBuild, forKey: Self.lastLoadedBuildKey)
        // DispatchQueue.main.async is FIFO; a Task per event is not, and events
        // landing out of order would reorder the transcript.
        await s.setEventHandler { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
        }
        session = s
        loadStep = nil
        preparing = nil
        Self.excludeModelsFromBackup()
        SpeechModel.removeUnusedSpeechModels(keep: choice)
        if case .loading = phase { phase = .ready }
        if case .failed = phase { phase = .ready }
        if inSession && phase != .transcribing { await catchUp(s) }
        #if DEBUG
        if let to = ProcessInfo.processInfo.environment["SPIEL_SWITCH_TO"].flatMap(SpeechModel.init(rawValue:)),
           to != choice, !switchingModel {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.switchModel(to: to) } }
            return true
        }
        if ProcessInfo.processInfo.environment["SPIEL_AUTOSTART"] == "1" {
            if let path = ProcessInfo.processInfo.environment["SPIEL_AUTOFILE"] {
                transcribeFile(URL(fileURLWithPath: path))
                return true
            }
            start(title: "Design review", location: "Workshop, Portland", keepAudio: true)
            if let secs = Double(ProcessInfo.processInfo.environment["SPIEL_AUTOSTOP"] ?? "") {
                DispatchQueue.main.asyncAfter(deadline: .now() + secs) { MainActor.assumeIsolated { self.stop() } }
            }
        }
        #endif
        return true
    }

    // MARK: - Speech model

    /// The speech model is re-downloadable, so it stays out of iCloud/device backups
    /// (Apple's data-storage rule; it would also add hundreds of MB to every backup).
    /// Transcripts and kept audio live in Documents and ARE backed up.
    private static func excludeModelsFromBackup() {
        var dir = AsrModels.defaultCacheDirectory(for: .v2).deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do { try dir.setResourceValues(values) } catch { DiagnosticLog.write("could not exclude models from backup: \(error)") }
    }

    private func noteLoading(_ text: String, step: Int = 0, fraction: Double? = nil) {
        // Downloaded: the rest is the Neural Engine load, which no longer blocks the screen.
        if step == 2, case .loading = phase {
            phase = .ready
            loadStep = nil
            preparing = "Preparing the speech model for the first time. This can take a few minutes."
            return
        }
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
        guard phase == .ready, !inSession else { return }
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                homeNote = "Microphone access is off. Settings → Spiel Listen → Microphone."
                return
            }
            if let session {
                await session.setGlossary(Glossary.load())
                await session.reset()
                feed.reset(attachedTo: session.sink)
            } else {
                feed.reset(attachedTo: nil)
                DiagnosticLog.write("meeting started before the model was ready; audio is queued")
            }
            finishing = false
            catchingUp = false
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
            guard openMic() else { startedAt = nil; homeNote = lastError; return }
            phase = .recording
            DiagnosticLog.write("meeting started: model ready \(session != nil), input \(AudioCapture.currentInputName), keep audio \(recorder != nil)")
            _ = capture.takeBufferStats(); _ = feed.takePassedSamples()
            health.start { [weak self] in self?.logHealth() }
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
        guard phase == .paused else { return }
        closePause()
        if openMic() { phase = .recording }
    }

    func stop() {
        guard isActive else { return }
        DiagnosticLog.write("stop pressed: model ready \(session != nil), audio going to the model \(feed.isAttached), \(doc.wordCount) words in the document")
        logHealth()
        health.stop()
        if phase == .paused { closePause() }
        capture.stop()
        phase = .ready
        autosave?.invalidate(); autosave = nil
        meter.reset(); level = 0
        let rec = recorder
        recorder = nil
        Task {
            await Task.detached { rec?.finish() }.value
            if let e = rec?.error { lastError = "The recording stopped early: \(e)" }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            if let session, feed.isAttached {
                await finishMeeting(session)
            } else {
                // The model is still loading: keep the screen up until it catches up.
                finishing = true
                endedAt = Date()
                save()
                if engineError != nil { closeAfterStop(nil) }
            }
        }
    }

    private func finishMeeting(_ session: DictationSession) async {
        UIApplication.shared.isIdleTimerDisabled = false
        let stoppedAt = endedAt  // set when Stop came before the model was ready
        let finishStarted = Date()
        let backlog = await session.backlog
        DiagnosticLog.write("finish: started with \(backlog.segmentsWaiting) segment(s) still to transcribe")
        let report = await session.finishWithReport()
        endedAt = stoppedAt ?? report.endedAt
        if !report.errors.isEmpty { DiagnosticLog.write("listen ended with errors: \(report.diagnosis)") }
        // If the model wrote more words than reached the document, text was lost on the way.
        let modelWords = report.text.split(whereSeparator: { $0.isWhitespace }).count
        DiagnosticLog.write("finish: done in \(String(format: "%.1f", Date().timeIntervalSince(finishStarted))) s; model took \(Int(report.audioSeconds)) s of audio, \(report.segments) segments, \(modelWords) words; document \(doc.wordCount) words; dropped buffers \(report.droppedBuffers)")
        save()
        runStopShortcut()
        closeAfterStop(nil)
    }

    /// Replays audio queued before the model was ready, then switches the mic to live.
    private func catchUp(_ session: DictationSession) async {
        catchingUp = true
        await session.setGlossary(Glossary.load())
        await session.reset()
        let started = Date()
        var replayed = 0
        while true {
            let items = feed.drainOrAttach(session.sink)
            if items.isEmpty { break }
            for item in items {
                switch item {
                case .samples(let s):
                    session.sink.submit(s); replayed += s.count
                case .pause(let span):
                    let at = await session.audioSeconds
                    await session.notePause(seconds: span)
                    doc.notePause(seconds: span, atOffset: at)
                    revision += 1
                }
            }
            await Task.yield()
        }
        DiagnosticLog.write("caught up: replayed \(replayed / 16_000) s of queued audio in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        if feed.overflowed { lastError = "The speech model took more than 15 minutes to load, so part of this meeting has no transcript." }
        if finishing {
            finishing = false
            catchingUp = false
            await finishMeeting(session)
            return
        }
        // Keep "Catching up" on screen until the queued audio has actually been written
        // out, not just handed over (0.5.1). Capped, so a stuck engine can't pin it.
        let target = Double(replayed) / 16_000 - 0.5
        let deadline = Date().addingTimeInterval(180)
        while inSession, Date() < deadline {
            let b = await session.backlog
            if b.takenSeconds >= target && b.segmentsWaiting == 0 { break }
            try? await Task.sleep(for: .milliseconds(400))
        }
        DiagnosticLog.write("catch-up written out \(String(format: "%.1f", Date().timeIntervalSince(started))) s after the model loaded")
        catchingUp = false
    }

    /// Closes the meeting or file screen and returns to Home.
    private func closeAfterStop(_ note: String?) {
        UIApplication.shared.isIdleTimerDisabled = false
        health.stop()
        finishing = false
        let saved = fileURL != nil && !doc.isEmpty
        homeNote = lastError ?? note ?? (saved ? "Saved: \(title)" : nil)
        lastError = nil
        startedAt = nil
        doc = TranscriptDocument()
        fileURL = nil
        audioURL = nil
        location = nil
        endedAt = nil
        sourceFile = nil
        savedCount += 1
    }

    // MARK: - Transcribe an audio file

    /// Same session, document and saved transcript as a meeting; only the samples differ.
    /// The picked file is copied in first: Files can hand over an iCloud file that is
    /// not on the phone yet, and the coordinated copy is what fetches it.
    func transcribeFile(_ picked: URL) {
        guard phase == .ready, !inSession, let session else { return }
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
            if startedAt != nil {
                if doc.isEmpty { closeAfterStop(nil) } else { reviewing = true }
            } else { homeNote = lastError; lastError = nil }
        }
    }

    /// Review screen → Save: the transcript is already saved (and re-saved on a rename).
    func finishReview() {
        guard reviewing else { return }
        reviewing = false
        save()
        closeAfterStop(nil)
    }

    /// Review screen → Delete: removes the saved transcript.
    func discardReview() {
        guard reviewing else { return }
        reviewing = false
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        lastError = nil
        closeAfterStop("Deleted")
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

    private func openMic() -> Bool {
        let sink = feed
        let rec = recorder
        let meter = self.meter
        do {
            try capture.start { samples in
                sink.submit(samples)
                rec?.append(samples)
                if let l = meter.feed(samples) {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.level = l; self.health.noteLevel(l) } }
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
        guard let pausedAt else { return }
        let span = Date().timeIntervalSince(pausedAt)
        self.pausedAt = nil
        pausedTotal += span
        guard let session, feed.isAttached else { feed.notePause(span); return }
        Task {
            let at = await session.audioSeconds
            await session.notePause(seconds: span)
            doc.notePause(seconds: span, atOffset: at)
            revision += 1
            save()
        }
    }

    // MARK: - Diagnostics

    /// TEMPORARY (0.5.3): one line per 30 s of a meeting; see MeetingHealth.
    private func logHealth() {
        let mic = capture.takeBufferStats()
        let toModel = feed.takePassedSamples()
        let window = health.takeWindow()
        let queued = Int(feed.waitingSeconds), flowing = feed.isAttached, words = doc.wordCount
        let s = session
        Task {
            let b = await s?.backlog
            let lastAgo = mic.lastAgo.map { String(format: "%.1f s ago", $0) } ?? "never"
            let model = b.map { "model has taken \(Int($0.takenSeconds)) s, \($0.segmentsWaiting) segment(s) waiting" } ?? "model not ready"
            DiagnosticLog.write("health: mic \(mic.count) buffers (last \(lastAgo)), \(window); \(flowing ? "flowing to the model" : "queued \(queued) s"), \(toModel / 16_000) s handed over; \(model); document \(words) words")
        }
    }

    private static func routeReason(_ raw: UInt?) -> String {
        guard let raw, let r = AVAudioSession.RouteChangeReason(rawValue: raw) else { return "unknown" }
        switch r {
        case .newDeviceAvailable: return "new device"
        case .oldDeviceUnavailable: return "device gone"
        case .categoryChange: return "category change"
        case .override: return "override"
        case .wakeFromSleep: return "wake from sleep"
        case .noSuitableRouteForCategory: return "no suitable route"
        case .routeConfigurationChange: return "route configuration change"
        default: return "reason \(raw)"
        }
    }

    // MARK: - Events

    private func handle(_ event: DictationSession.Event) {
        health.note(event)
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
            inputDevice: AudioCapture.currentInputName, engine: speechModel.engineName,
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
        // Logged only, to see on a real phone whether any of these line up with the
        // point where the audio stopped (0.5.3). Nothing is done in response.
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DiagnosticLog.write("iOS: audio engine configuration changed while \(self.phase)") }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DiagnosticLog.write("iOS: audio services were reset while \(self.phase)") }
        })
        observers.append(nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DiagnosticLog.write("iOS: memory warning while \(self.phase)") }
        })
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DiagnosticLog.write("app went to the background while \(self.phase)") }
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DiagnosticLog.write("app came back while \(self.phase)") }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { n in
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let opts = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                DiagnosticLog.write("iOS: audio interruption \(raw == AVAudioSession.InterruptionType.began.rawValue ? "began" : "ended") while \(self.phase)")
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
                DiagnosticLog.write("iOS: audio route changed (\(Self.routeReason(reason))), input now \(AudioCapture.currentInputName), while \(self.phase)")
                guard self.phase == .recording,
                      reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
                        || reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                self.capture.stop()
                guard self.openMic() else { return }
                let name = AudioCapture.currentInputName
                guard let session = self.session, self.feed.isAttached else { return }
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
