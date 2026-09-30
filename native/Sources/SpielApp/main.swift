import AppKit
import AVFoundation
import Foundation
import SpielCore
import SwiftUI
import UserNotifications

/// Spiel v2 — native menu-bar dictation.
///
/// Runs as an LSUIElement (no dock icon). Everything the user needs is on the status
/// item, including — deliberately — the hotkey's health, so a failed registration is
/// visible instead of looking like a working app that ignores you.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let hotkeys = HotkeyManager()
    private let panel = RecordingPanel()
    private let inserter = TextInserter()
    private let capture = AudioCapture()

    private var session: DictationSession?
    private var engineReady = false
    /// Dictation lifecycle. A hotkey press during `starting` or `finishing` is
    /// IGNORED (and logged), never acted on: a fast second press used to call
    /// `reset()` while the previous `finish()` was still suspended inside the
    /// session actor, and actors are reentrant.
    enum Mode: Equatable { case dictation, listen }
    /// `paused` is Listen-only: capture stopped, session still armed.
    private enum Phase: Equatable {
        case idle, starting(Mode), recording(Mode), paused, finishing(Mode)
    }
    private var phase: Phase = .idle
    /// Either mode is capturing (a paused Listen is not).
    private var isRecording: Bool { if case .recording = phase { return true }; return false }
    private var isDictating: Bool { phase == .recording(.dictation) }
    private var isListening: Bool { phase == .recording(.listen) || phase == .paused }
    /// Secure Input holder lookup shells out to `ioreg`; cache it and resolve it off
    /// the main thread so opening the menu never stalls.
    private var secureHolderCache: (value: String?, at: Date)?
    private var secureHolderLookupRunning = false
    private var hotkeyStatus: HotkeyManager.Status = .unregistered
    private var listenHotkeyStatus: HotkeyManager.Status = .unregistered
    private var lastError: String?
    /// What the last dictation did, in one line. Lives in the menu because the menu
    /// is the only surface the user actually opens when "nothing happened".
    private var lastOutcome: String?
    /// Running transcript for the panel preview; reset on every start.
    private var previewText = ""
    private var accessibilityPoll: Timer?

    // MARK: Listen state
    private let listenPanel = ListenPanel()
    /// The transcript. The file on disk is the truth and the panel is a view of
    /// it; both read from here and nothing else holds text.
    private var listenDoc: TranscriptDocument?
    private var listenURL: URL?
    private var listenStartedAt: Date?
    /// Fixed at finish so a title edit in the done state re-renders the same
    /// `ended:` instead of "now".
    private var listenEndedAt: Date?
    /// Which handler session events go to. Set with the mode at capture start —
    /// not derived from `listenDoc`, which outlives the session for the done
    /// state's Copy/Open and would otherwise swallow the next dictation's events.
    private var eventsGoToListen = false
    private var listenTitle = ""
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0
    private var autosave: Timer?
    private var listenCounter: Timer?
    /// Consecutive engine failures in this Listen session; 3 in a row is a
    /// wedged engine and gets a notification (see `handleListen`).
    private var consecutiveFailures = 0
    private var listenSaveErrorNotified = false
    /// Listen counterpart of `lastOutcome`, one line in the menu.
    private var lastSession: String?
    /// Name of the engine behind `session`, for the transcript's frontmatter.
    private var engineName = "unknown"

    // MARK: 2.4 — settings, history, diagnostics
    private let settings = SpielSettings()
    private let settingsModel = SettingsModel()
    private let historyModel = HistoryModel()
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var history = DictationHistory()
    /// The last dictated text, kept in memory even with history off, so Copy Last
    /// Dictation works either way. Never set for a Secure Input dictation.
    private var lastDictationText: String?
    /// Hold-to-talk: the key came up while the mic was still opening. Honoured the
    /// moment capture begins, so a quick tap does not leave the mic open.
    private var holdReleasePending = false
    /// The engine was changed in Settings while a session was running; reload once
    /// the app is idle again (see `updateStatusItem`).
    private var engineReloadPending = false
    private var isWarming = false
    /// Set while Settings tries a shortcut, so a refused combo does not ALSO raise a
    /// "hotkey is not active" notification — Settings shows the reason inline and
    /// puts the previous combo back.
    private var quietHotkeyFailures = false

    // MARK: 2.5 — first-run setup
    private let setupModel = SetupModel()
    private var setupWindow: NSWindow?
    /// 1 s poll of the permissions while the setup window is open.
    private var setupPoll: Timer?
    /// The window was opened by the launch decision (not the menu), so closing it
    /// is where the launch-time permission requests it replaced still happen.
    private var setupShownAtLaunch = false
    /// Last integer percent pushed to the window, so a progress callback per
    /// network chunk does not redraw SwiftUI hundreds of times a second.
    private var lastModelPercent = -1
    /// The chosen model was complete on disk when warm-up began. FluidAudio still
    /// reports a file walk for a cached model; that is not a download to show.
    private var modelWasOnDisk = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticLog.write("launch — Spiel \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") pid \(ProcessInfo.processInfo.processIdentifier)")
        // Two copies of Spiel (an older build left running while a new one is
        // opened — seven builds shipped on 2026-09-02 alone) fight over one global
        // hotkey: the second loses with "another app already owns ⌘⇧D", which reads
        // as a conflict with some OTHER app. Name the real cause.
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty {
                let pids = others.map { "\($0.processIdentifier)" }.joined(separator: ", ")
                let msg = "another copy of Spiel is already running (pid \(pids)) — quit it from its menu-bar icon, or the hotkey will belong to whichever started first"
                DiagnosticLog.write("WARNING: \(msg)")
                lastError = msg
                Notifier.post(title: "Two copies of Spiel are running", body: msg)
            }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Rebuild the menu each time it opens, so Secure Input / Accessibility /
        // engine state are read at that instant rather than frozen at the last event.
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem()

        // Permissions are still asked for at LAUNCH, never on the first hotkey press
        // (see `requestPermissionsAtLaunch`) — but since 2.5 a fresh install gets the
        // setup window instead, which asks for each one with its reason beside it.
        // An upgrade with everything already granted sees no window at all.
        Task { await self.decideSetupAtLaunch() }

        installMainMenu()
        let loaded = DictationHistory.load()
        history = loaded.history
        lastDictationText = history.last?.text
        if let note = loaded.note {
            DiagnosticLog.write("history: \(note)")
            historyModel.note = note
        }
        wireSettingsModel()
        wireHistoryModel()

        hotkeys.setStatusHandler { [weak self] id, status in
            // Synchronous: registration runs on the main thread, and Settings reads
            // the status straight after `register` returns.
            MainActor.assumeIsolated {
                guard let self else { return }
                switch id {
                case .dictation: self.hotkeyStatus = status
                case .listen: self.listenHotkeyStatus = status
                }
                // Not a console log. A dead hotkey must be visible.
                if case .failed(let desc, let reason) = status, !self.quietHotkeyFailures {
                    Notifier.post(
                        title: "Spiel hotkey is not active",
                        body: "\(desc) could not be registered: \(reason). Pick a different shortcut from the Spiel menu."
                    )
                }
                self.updateStatusItem()
            }
        }
        registerHotkey(.dictation, settings.dictationCombo)
        registerHotkey(.listen, settings.listenCombo)

        // Warm the model at launch, not on first keypress. A cold Parakeet load is
        // seconds; paying it while the user is already talking is the worst moment.
        Task { await self.warmUp() }
    }

    /// What TCC keys the grant on. Ad-hoc builds change identity on every rebuild,
    /// which is why a grant that shows ON can still be ineffective.
    static func signatureSummary() -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-d", "-r-", Bundle.main.bundlePath]
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = pipe
        do { try task.run() } catch { return "unknown" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        let line = out.split(separator: "\n").first { $0.contains("designated =>") }
        return line.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "no designated requirement (unsigned?)"
    }

    /// Ask for every permission at LAUNCH, not on the first hotkey press. The first
    /// test build asked for the mic on the first ⌘⇧D, which meant the entire first
    /// dictation was spent looking at a TCC dialog while the engine ran on silence,
    /// and asked for notification permission only when it first had something to
    /// say — so that first message was lost too. Since 2.5 this runs when the setup
    /// window is NOT shown (setup done before, or nothing missing); when it is, the
    /// window's own buttons ask, and closing it runs `foldPermissionsAfterSetup`.
    private func requestPermissionsAtLaunch() {
        Notifier.requestAuthorization()
        Task {
            let auth = AudioCapture.microphoneAuthorization()
            DiagnosticLog.write("microphone permission at launch: \(auth.rawValue); default input: \(AudioCapture.defaultInputDeviceName())")
            if auth == .notDetermined {
                let granted = await AudioCapture.requestMicrophoneAccess()
                DiagnosticLog.write("microphone permission prompt → \(granted ? "granted" : "denied")")
            }
        }
        if !TextInserter.hasAccessibilityPermission() {
            DiagnosticLog.write("accessibility NOT effective at launch — prompting. If System Settings already shows Spiel ON, that grant belongs to a differently-signed build: remove it and re-add. Signature: \(Self.signatureSummary())")
            TextInserter.requestAccessibilityPermission()
            startAccessibilityPoll()
        }
    }

    /// Accessibility grants do not notify the app; the first build needed a restart
    /// before the warning triangle went away. Poll cheaply until it is granted.
    private func startAccessibilityPoll() {
        accessibilityPoll?.invalidate()
        accessibilityPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop; the delegate is @MainActor.
            MainActor.assumeIsolated {
                guard let self else { return }
                if TextInserter.hasAccessibilityPermission() {
                    self.accessibilityPoll?.invalidate()
                    self.accessibilityPoll = nil
                    DiagnosticLog.write("accessibility granted")
                    self.updateStatusItem()
                }
            }
        }
    }

    /// Builds a prepared session wired to the event handler. Both the primary and
    /// the fallback engine need exactly this; having it written twice is how the
    /// two paths drift apart.
    private func makeSession(_ transcriber: Transcriber) async throws -> DictationSession {
        let s = DictationSession(transcriber: transcriber)
        try await s.prepare()
        await s.setEventHandler { [weak self, weak s] event in
            Task { @MainActor in
                // A session the watchdog abandoned can still finish a transcribe
                // later and emit `.textReleased`; only the CURRENT session may drive
                // the preview, or a minute-old sentence lands in the next dictation's
                // panel (codex review of build 8).
                guard let self, let s, self.session === s else { return }
                self.handle(event)
            }
        }
        return s
    }

    private func makeTranscriber(_ choice: EngineChoice) -> Transcriber {
        // Download progress reaches the setup window. DispatchQueue.main, not a
        // Task per callback: Tasks do not run in submission order, and a bar that
        // steps backwards is worse than none.
        let progress: ModelProgressHandler = { [weak self] p in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.noteModelProgress(p, choice: choice) } }
        }
        switch choice {
        case .unified: return ParakeetUnifiedTranscriber(progress: progress)
        case .v3: return ParakeetTranscriber(progress: progress)
        case .apple: return AppleSpeechTranscriber()
        }
    }

    /// Loads the engine picked in Settings, falling back through the others
    /// (`EngineChoice.fallbackOrder`). The default choice gives exactly the 2.3
    /// order: Parakeet Unified EN (fewest errors on his own voice, 2026-09-23), TDT
    /// v3, then Apple. A failed download degrades the engine, never the app.
    private func warmUp() async {
        isWarming = true
        defer { isWarming = false; updateStatusItem() }
        let t0 = Date()
        let chosen = settings.engine
        lastModelPercent = -1
        setupModel.engine = chosen
        modelWasOnDisk = SpeechModels.isDownloaded(chosen)
        setupModel.model = modelWasOnDisk ? .compiling : .checking
        var failures: [String] = []
        for choice in EngineChoice.fallbackOrder(chosen) {
            do {
                let s = try await makeSession(makeTranscriber(choice))
                self.session = s
                self.engineName = choice.engineName
                self.engineReady = true
                setupModel.model = choice == chosen
                    ? .ready(engine: SpeechModels.displayName(choice), bytes: SpeechModels.bytesOnDisk(choice))
                    : .fallback(using: SpeechModels.displayName(choice), error: failures.first ?? "unknown error")
                self.lastError = choice == chosen ? nil : "\(chosen.engineName) unavailable, using \(choice.engineName)"
                DiagnosticLog.write("engine ready: \(choice.engineName)\(choice == chosen ? "" : " (fallback from \(chosen.engineName))") (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
                // Prime the vocabulary boost now (first launch downloads its ~98 MB
                // CTC model) so the first dictation is boosted too; every dictation
                // start re-hands the list, which only rebuilds when the file changed.
                if choice == .unified { await s.setGlossary(Glossary.load()) }
                return
            } catch {
                failures.append("\(choice.engineName): \(error)")
                DiagnosticLog.write("\(choice.engineName) failed to load: \(error)")
            }
        }
        self.engineReady = false
        self.lastError = "no speech engine could load: \(failures.joined(separator: "; "))"
        setupModel.model = .failed(failures.joined(separator: "\n"))
        DiagnosticLog.write("NO engine could load")
    }

    private func handle(_ event: DictationSession.Event) {
        // Routed by the mode that opened the mic, not by phase: a Listen session's
        // last segment can land after `finish` returns, and it still belongs to
        // the Listen document.
        if eventsGoToListen { handleListen(event); return }
        switch event {
        case .speechStarted:
            panel.setStatus("Listening…")
        case .segmentCaptured:
            panel.setStatus("Transcribing…")
        case .textReleased(let t, _, _, _):
            previewText = previewText.isEmpty ? t : previewText + " " + t
            panel.setTranscript(TranscriptAssembler.tidy(previewText))
            panel.setStatus("Listening…")
        case .error(let e, _, _):
            lastError = e
            DiagnosticLog.write("segment error: \(e)")
        }
    }

    private func handleListen(_ event: DictationSession.Event) {
        guard var doc = listenDoc else { return }
        switch event {
        case .speechStarted, .segmentCaptured:
            break
        case .textReleased(let t, let at, let gap, _):
            let before = doc.paragraphs.count
            doc.append(text: t, startOffset: at, gapBefore: gap)
            listenDoc = doc
            consecutiveFailures = 0
            listenPanel.setDocument(doc)
            // Autosave on every paragraph break (plus the 30 s timer), so a crash
            // costs at most the paragraph in progress. After the session has
            // finished there is no timer, so a late-landing segment saves at once.
            if doc.paragraphs.count != before || !isListening { saveListen() }
        case .error(let e, let at, let secs):
            lastError = e
            DiagnosticLog.write("listen segment error: \(e)")
            // A failed segment is a gap, not a stop: mark the hole and keep going.
            doc.noteMissed(seconds: secs, atOffset: at)
            listenDoc = doc
            listenPanel.setDocument(doc)
            consecutiveFailures += 1
            if consecutiveFailures == 3 {
                let msg = "the speech engine failed 3 segments in a row — it may be wedged; stop and restart Listen (the transcript so far is saved)"
                DiagnosticLog.write("LISTEN: \(msg)")
                Notifier.post(title: "Spiel Listen is losing speech", body: msg)
            }
            saveListen()
        }
    }

    // MARK: - Recording

    private func toggle() {
        switch phase {
        case .idle: start()
        case .recording(.dictation): stop()
        case .recording(.listen), .paused:
            // One AudioCapture, one session: dictation during Listen is refused
            // with a reason, not multiplexed (design §5.1).
            let mins = listenStartedAt.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
            let msg = "Listen is running (\(mins) min) — stop it to dictate"
            DiagnosticLog.write("dictation refused: \(msg)")
            Notifier.post(title: "Spiel is listening", body: msg)
        case .starting, .finishing:
            DiagnosticLog.write("hotkey ignored: \(phase)")
        }
    }

    private func toggleListen() {
        switch phase {
        case .idle: startListening()
        case .recording(.listen), .paused: stopListening()
        case .recording(.dictation):
            DiagnosticLog.write("listen refused: dictation in progress")
            Notifier.post(title: "Spiel is dictating", body: "Finish the dictation (⌘⇧D) before starting Listen")
        case .starting, .finishing:
            DiagnosticLog.write("listen hotkey ignored: \(phase)")
        }
    }

    private func start() {
        guard engineReady, let session else {
            let why = lastError ?? "the speech engine is still loading"
            DiagnosticLog.write("start refused: \(why)")
            Notifier.post(title: "Spiel is not ready", body: why)
            return
        }
        switch AudioCapture.microphoneAuthorization() {
        case .authorized:
            break
        case .notDetermined:
            // Prompt now and start once answered, instead of running the engine on
            // silence underneath the dialog.
            DiagnosticLog.write("start: microphone permission not determined — prompting")
            Task {
                let granted = await AudioCapture.requestMicrophoneAccess()
                DiagnosticLog.write("microphone permission prompt → \(granted ? "granted" : "denied")")
                if granted { self.start() } else { self.micDenied() }
            }
            return
        case .denied, .restricted:
            micDenied()
            return
        }
        // Re-read the vocabulary file so an edit takes effect on the next dictation.
        let glossary = Glossary.load()
        // Capture the target app BEFORE our panel appears.
        inserter.captureFrontmostApp()
        // Latch Secure Input as observed AT THE START of this dictation. Sampling it
        // later (at log time) is not equivalent: by then `insert()` has refocused the
        // target app and, on the failure path, spent up to 3 s shelling out to
        // `ioreg`, and Secure Input is routinely released the moment a password field
        // loses focus. A dictated password would then be logged verbatim because the
        // flag had already flipped back — the guard reading as working while doing
        // nothing.
        let secureAtStart = TextInserter.isSecureInputEnabled()
        secureInputSeenThisDictation = secureAtStart
        capture.preferredDeviceUID = settings.microphone?.uid
        DiagnosticLog.write("start: target app = \(inserter.capturedAppName ?? "?"), input device = \(inputDeviceLabel()), secure input = \(secureAtStart), vocabulary = \(glossary.count) aliases")
        // reset() re-arms the audio path and must complete BEFORE the mic starts
        // submitting, or the first buffers land in a disarmed sink. It is awaited,
        // not blocked on: the main actor stays free (menu, hotkey, UI), and a press
        // that lands in the gap is ignored by `toggle()` via `phase`.
        phase = .starting(.dictation)
        eventsGoToListen = false
        updateStatusItem()
        Task {
            // One task, in order: two separate Tasks against the same actor have no
            // ordering guarantee between them, and a glossary swap that landed after
            // reset() would still work but one that landed after the first segment's
            // release would apply the OLD vocabulary to that segment's preview.
            await session.setGlossary(glossary)
            await session.reset()
            await MainActor.run { self.beginCapture(session, mode: .dictation) }
        }
    }

    /// Opens the mic into `session`. Shared by both modes and by Listen's resume;
    /// the capture handler is identical, only what happens after differs.
    @discardableResult
    private func openMicrophone(into session: DictationSession, mode: Mode) -> Bool {
        do {
            try capture.start(handler: { [weak self] samples in
                guard let self else { return }
                // Synchronous, ordered handoff — see AudioSink. A Task per buffer
                // has no ordering guarantee and would shuffle mic audio.
                session.sink.submit(samples)
                // Cheap RMS for the meter; the real VAD is Silero inside the session.
                var sum: Float = 0
                for s in samples { sum += s * s }
                let rms = (samples.isEmpty ? 0 : (sum / Float(samples.count)).squareRoot())
                // dB mapping tuned to a laptop mic at conversational distance:
                // -48 dBFS -> empty, -18 dBFS -> full. The first mapping (-50..-10)
                // put normal speech at ~40% and Christopher asked for more motion.
                let db = 20 * log10(max(rms, 1e-6))
                let level = min(max((db + 48) / 30, 0), 1)
                Task { @MainActor in
                    if mode == .listen { self.listenPanel.update(level: level) } else { self.panel.update(level: level) }
                }
            }, onRouteChange: { [weak self] outcome in
                // Called on the capture's private queue; hop to the main actor.
                Task { @MainActor in self?.captureRouteChanged(outcome, session: session, mode: mode) }
            })
            return true
        } catch {
            DiagnosticLog.write("microphone failed to start: \(error)")
            Notifier.post(title: "Spiel could not open the microphone", body: "\(error)")
            if mode == .listen { lastSession = "microphone failed to start: \(error)" }
            else { lastOutcome = "microphone failed to start: \(error)" }
            return false
        }
    }

    private func beginCapture(_ session: DictationSession, mode: Mode) {
        guard phase == .starting(mode) else { return }
        guard openMicrophone(into: session, mode: mode) else {
            phase = .idle
            updateStatusItem()
            return
        }
        phase = .recording(mode)
        switch mode {
        case .dictation:
            previewText = ""
            panel.setTranscript("")
            panel.show(status: "Listening…")
            if holdReleasePending {
                // Hold-to-talk key came up while the mic was opening: stop now.
                holdReleasePending = false
                DiagnosticLog.write("hold-to-talk: key released before capture began — stopping")
                updateStatusItem()
                stop()
                return
            }
        case .listen:
            let doc = TranscriptDocument()
            eventsGoToListen = true
            listenDoc = doc
            listenURL = nil
            listenStartedAt = Date()
            listenEndedAt = nil
            pausedAt = nil
            pausedTotal = 0
            consecutiveFailures = 0
            listenSaveErrorNotified = false
            listenPanel.begin(title: listenTitle, document: doc)
            listenPanel.onTitleChanged = { [weak self] title in
                Task { @MainActor in
                    guard let self else { return }
                    self.listenTitle = title
                    if self.listenDoc != nil { self.saveListen() }  // rename follows the title
                }
            }
            listenPanel.onPause = { [weak self] in Task { @MainActor in self?.pauseListening() } }
            listenPanel.onResume = { [weak self] in Task { @MainActor in self?.resumeListening() } }
            listenPanel.onStop = { [weak self] in Task { @MainActor in self?.stopListening() } }
            listenPanel.onCopy = { [weak self] in Task { @MainActor in self?.copyListen() } }
            listenPanel.onOpen = { [weak self] in Task { @MainActor in self?.openListen() } }
            autosave?.invalidate()
            autosave = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveListen() }
            }
            listenCounter?.invalidate()
            listenCounter = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickListen() }
            }
            tickListen()
            // First save immediately: an empty file with frontmatter is proof the
            // folder is writable BEFORE an hour of transcript depends on it.
            saveListen()
        }
        updateStatusItem()
    }

    /// The audio route changed and capture restarted (or failed to).
    private func captureRouteChanged(_ outcome: String, session: DictationSession, mode: Mode) {
        guard self.session === session else { return }
        let failed = outcome.hasPrefix("could not restart capture")
        DiagnosticLog.write("route change (\(mode)): \(outcome)")
        guard mode == .listen, var doc = listenDoc, isListening else {
            if failed { lastError = outcome }
            return
        }
        Task {
            let at = await session.audioSeconds
            await session.noteCaptureRestart()
            await MainActor.run {
                if failed {
                    doc.noteCaptureRestart(device: "nothing — \(outcome)", atOffset: at)
                    self.listenDoc = doc
                    self.listenPanel.setDocument(doc)
                    self.saveListen()
                    Notifier.post(title: "Spiel Listen stopped",
                                  body: "input device changed and could not restart (\(outcome)). The transcript so far is saved.")
                    self.stopListening()
                } else {
                    doc.noteCaptureRestart(device: outcome, atOffset: at)
                    self.listenDoc = doc
                    self.listenPanel.setDocument(doc)
                    self.saveListen()
                    // No notification on a successful restart: the marker and the
                    // counter are the signal, and a mid-meeting alert is noise.
                }
            }
        }
    }

    private func micDenied() {
        let msg = "Microphone access is denied. System Settings → Privacy & Security → Microphone → enable Spiel."
        DiagnosticLog.write("start refused: microphone denied")
        phase = .idle
        lastOutcome = msg
        Notifier.post(title: "Spiel cannot hear you", body: msg)
        updateStatusItem()
    }

    /// If the engine never returns, `phase` would stay `finishing` forever: every
    /// hotkey press "ignored", the menu's Start/Stop item inert, the panel stuck on
    /// "Finishing…" — a dead app that can only be quit. Nothing has hung yet; this
    /// exists because that is the one state the app cannot recover from on its own.
    /// Generous, because a 14 s segment on a cold Neural Engine is a few seconds.
    private static let finishWatchdogSeconds: UInt64 = 60
    private var finishGeneration = 0
    /// Whether macOS Secure Input was seen on at any point during the current
    /// dictation. Latched at `start()`, re-checked in `deliver()`, and consumed by
    /// `quotedForLog`; see those for why a live sample at log time is wrong.
    private var secureInputSeenThisDictation = false

    private func stop() {
        guard phase == .recording(.dictation) else { return }
        finish(mode: .dictation)
    }

    /// Ends either mode: stop the mic, drain the session, deliver. The watchdog
    /// is the same for both — on a hung engine a dictation is lost, a Listen keeps
    /// its last autosave and says so.
    private func finish(mode: Mode) {
        guard let session else { return }
        capture.stop()
        autosave?.invalidate(); autosave = nil
        phase = .finishing(mode)
        if mode == .dictation { panel.setStatus("Finishing…") } else { listenPanel.setFinishing() }
        updateStatusItem()
        finishGeneration += 1
        let generation = finishGeneration
        Task {
            let report = await session.finishWithReport()
            await MainActor.run {
                // A finish that comes back after the watchdog already replaced the
                // session is stale: its text would be delivered into whatever he is
                // doing now, a minute later.
                guard self.finishGeneration == generation, self.phase == .finishing(mode) else {
                    DiagnosticLog.write(
                        "stale finish ignored (watchdog already fired) — text was: "
                            + self.quotedForLog(report.text),
                        sensitive: true
                    )
                    return
                }
                self.phase = .idle
                switch mode {
                case .dictation:
                    self.panel.hide()
                    self.deliver(report)
                case .listen:
                    self.deliverTranscript(report)
                }
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: Self.finishWatchdogSeconds * 1_000_000_000)
            await MainActor.run {
                guard self.finishGeneration == generation, self.phase == .finishing(mode) else { return }
                let msg: String
                switch mode {
                case .dictation:
                    msg = "the speech engine did not return within \(Self.finishWatchdogSeconds)s — reloading it; that dictation is lost"
                    self.panel.hide()
                    self.lastOutcome = msg
                case .listen:
                    let upTo = self.listenDoc?.paragraphs.last.map { TranscriptDocument.formatOffset($0.offset) } ?? "00:00"
                    msg = "the speech engine did not return within \(Self.finishWatchdogSeconds)s — reloading it; the transcript is saved up to \(upTo)"
                    self.listenEndedAt = Date()
                    self.saveListen()
                    self.listenCounter?.invalidate(); self.listenCounter = nil
                    self.lastSession = "saved up to \(upTo), engine hung"
                    self.listenPanel.setDone(summary: "saved up to \(upTo) · engine hung", document: self.listenDoc ?? TranscriptDocument())
                }
                DiagnosticLog.write("WATCHDOG: \(msg)")
                self.phase = .idle
                self.lastError = msg
                // Drop the wedged session and build a fresh one; the old one's tasks
                // are abandoned, not awaited (awaiting is the thing that hung).
                self.session = nil
                self.engineReady = false
                self.updateStatusItem()
                Notifier.post(title: "Spiel got stuck finishing", body: msg)
                Task { await self.warmUp() }
            }
        }
    }

    // MARK: - Listen

    private func startListening() {
        guard engineReady, let session else {
            let why = lastError ?? "the speech engine is still loading"
            DiagnosticLog.write("listen refused: \(why)")
            Notifier.post(title: "Spiel is not ready", body: why)
            return
        }
        switch AudioCapture.microphoneAuthorization() {
        case .authorized:
            break
        case .notDetermined:
            DiagnosticLog.write("listen: microphone permission not determined — prompting")
            Task {
                let granted = await AudioCapture.requestMicrophoneAccess()
                DiagnosticLog.write("microphone permission prompt → \(granted ? "granted" : "denied")")
                if granted { self.startListening() } else { self.micDenied() }
            }
            return
        case .denied, .restricted:
            micDenied()
            return
        }
        let glossary = Glossary.load()
        // No captureFrontmostApp() and no Secure Input latch: Listen never pastes
        // and has no target field (design §5.6). The frontmost window title is
        // read for the default session title only.
        listenTitle = WindowTitle.frontmost() ?? ""
        capture.preferredDeviceUID = settings.microphone?.uid
        DiagnosticLog.write("listen start: title = \"\(listenTitle)\", input device = \(inputDeviceLabel()), vocabulary = \(glossary.count) aliases")
        phase = .starting(.listen)
        updateStatusItem()
        Task {
            await session.setGlossary(glossary)
            await session.reset()
            await MainActor.run { self.beginCapture(session, mode: .listen) }
        }
    }

    private func stopListening() {
        guard isListening else { return }
        if phase == .paused { closePause() }  // a stop while paused still books the pause
        finish(mode: .listen)
    }

    private func pauseListening() {
        guard phase == .recording(.listen) else { return }
        capture.stop()
        pausedAt = Date()
        phase = .paused
        listenPanel.setPaused(true)
        DiagnosticLog.write("listen paused")
        updateStatusItem()
    }

    /// Books the pause span onto the session and the document. The document's
    /// marker sits at the current audio offset, so it lands on the timeline
    /// between the speech before and after it.
    private func closePause() {
        guard let session, let pausedAt else { return }
        let span = Date().timeIntervalSince(pausedAt)
        self.pausedAt = nil
        pausedTotal += span
        Task {
            let at = await session.audioSeconds
            await session.notePause(seconds: span)
            await MainActor.run {
                guard var doc = self.listenDoc else { return }
                doc.notePause(seconds: span, atOffset: at)
                self.listenDoc = doc
                self.listenPanel.setDocument(doc)
                self.saveListen()
            }
        }
    }

    private func resumeListening() {
        guard phase == .paused, let session else { return }
        closePause()
        // The session stayed armed through the pause, so no reset() and no lost
        // tail — just open the mic into it again.
        guard openMicrophone(into: session, mode: .listen) else {
            // The mic would not reopen: end the session with what we have.
            DiagnosticLog.write("listen resume: microphone failed — stopping")
            finish(mode: .listen)
            return
        }
        phase = .recording(.listen)
        listenPanel.setPaused(false)
        DiagnosticLog.write("listen resumed")
        updateStatusItem()
    }

    private func tickListen() {
        guard let started = listenStartedAt, let doc = listenDoc, isListening else { return }
        let elapsed = Date().timeIntervalSince(started)
        listenPanel.setCounter(elapsed: elapsed, words: doc.wordCount, paused: phase == .paused)
    }

    private func listenFrontmatter(endedAt: Date) -> TranscriptDocument.Frontmatter {
        TranscriptDocument.Frontmatter(
            title: listenTitle, startedAt: listenStartedAt ?? endedAt, endedAt: endedAt,
            version: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "dev")",
            inputDevice: capture.activeDeviceName ?? AudioCapture.defaultInputDeviceName(), engine: engineName
        )
    }

    /// Autosave. The file is written under the CURRENT title; a title change moves
    /// it (`replacing:`). Failure is surfaced once per session, not once per 30 s.
    private func saveListen() {
        guard let doc = listenDoc, let started = listenStartedAt else { return }
        let text = doc.render(frontmatter: listenFrontmatter(endedAt: listenEndedAt ?? Date()))
        let url = TranscriptStore.url(for: listenTitle, startedAt: started, current: listenURL)
        do {
            try TranscriptStore.save(text, to: url, replacing: listenURL)
            listenURL = url
        } catch {
            lastError = "transcript autosave failed: \(error)"
            DiagnosticLog.write("LISTEN: autosave FAILED: \(error)")
            if !listenSaveErrorNotified {
                listenSaveErrorNotified = true
                Notifier.post(title: "Spiel cannot save the transcript",
                              body: "\(error). Listen keeps going; Copy from the panel when you stop.")
            }
        }
    }

    private func deliverTranscript(_ report: DictationSession.Report) {
        listenCounter?.invalidate(); listenCounter = nil
        if report.droppedBuffers > 0 {
            DiagnosticLog.write("WARNING: \(report.droppedBuffers) audio buffers were dropped (sink not armed)")
        }
        let doc = listenDoc ?? TranscriptDocument()
        listenEndedAt = report.endedAt
        saveListen()
        let mins = Int(report.endedAt.timeIntervalSince(report.startedAt) / 60)
        let words = doc.wordCount
        let file = listenURL?.lastPathComponent ?? "(not saved — \(lastError ?? "unknown error"))"
        var summary = "\(mins) min · \(words.formatted()) words · saved"
        if listenURL == nil { summary = "\(mins) min · \(words.formatted()) words · NOT SAVED" }
        if !report.errors.isEmpty { summary += " · \(report.errors.count) missed" }
        lastSession = "\(mins) min, \(words.formatted()) words, \(listenURL == nil ? "NOT saved" : "saved to \(file)")"
        DiagnosticLog.write("listen finished: \(lastSession!) (\(report.diagnosis); restarts \(report.captureRestarts), paused \(Int(report.pausedSeconds)) s)")
        listenPanel.setDone(summary: summary, document: doc)
        updateStatusItem()
    }

    private func copyListen() {
        guard let doc = listenDoc else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(doc.body(plain: true), forType: .string)
        listenPanel.flashCopied()
    }

    private func openListen() {
        saveListen()
        if let url = listenURL { NSWorkspace.shared.open(url) }
    }

    @objc private func openTranscriptsFolder() {
        let folder = TranscriptStore.defaultFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// Every dictation ends with ONE line saying what happened — inserted where and
    /// how, or exactly why not. An empty transcript used to `return` silently here,
    /// which made "the mic gave us nothing", "no speech detected" and "paste blocked"
    /// all look identical from the outside: a panel that disappears and no text.
    /// How a transcript is rendered into `Spiel.log`.
    ///
    /// Verbatim is the point of that log — "it said nothing happened" is only
    /// debuggable if the text is there. The one exception is a dictation taken while
    /// macOS Secure Input was active: Secure Input is on precisely because the
    /// focused field is a password field, so that transcript is plausibly a
    /// credential and must not be written to a file at all. Length is kept, because
    /// "did it hear anything?" is still the first debugging question.
    private func quotedForLog(_ text: String) -> String {
        guard !secureInputSeenThisDictation else {
            return "[\(text.count) chars withheld — macOS Secure Input was active, so this may be a password]"
        }
        return "\"\(text)\""
    }

    private func deliver(_ report: DictationSession.Report) {
        // Sticky OR: Secure Input at ANY point of this dictation makes the transcript
        // unloggable. It can come on mid-dictation (he tabs into a password field) as
        // easily as it can go off before delivery, and only one of those two mistakes
        // writes a credential to disk.
        secureInputSeenThisDictation = secureInputSeenThisDictation || TextInserter.isSecureInputEnabled()
        if report.droppedBuffers > 0 {
            DiagnosticLog.write("WARNING: \(report.droppedBuffers) audio buffers were dropped (sink not armed)")
        }
        guard !report.text.isEmpty else {
            let why = report.diagnosis
            lastOutcome = "nothing inserted — \(why)"
            DiagnosticLog.write("finish: no text — \(why)")
            Notifier.post(title: "Spiel heard nothing usable", body: why)
            updateStatusItem()
            return
        }
        let outcome = inserter.insert(report.text)
        let target = inserter.capturedAppName ?? "the previous app"
        recordHistory(report.text, app: inserter.capturedAppName)
        if outcome.success {
            lastOutcome = "inserted \(report.text.split(separator: " ").count) words into \(target) via \(outcome.method.rawValue) (\(report.diagnosis))" + (outcome.detail.map { " — \($0)" } ?? "")
            DiagnosticLog.write("finish: \(lastOutcome!) — \(quotedForLog(report.text))", sensitive: true)
        } else {
            let why = outcome.detail ?? "unknown reason — the text is on your clipboard"
            lastOutcome = "could not insert into \(target): \(why)"
            DiagnosticLog.write(
                "finish: INSERT FAILED into \(target): \(why) — text: \(quotedForLog(report.text))",
                sensitive: true
            )
            Notifier.post(title: "Spiel could not insert the text", body: why)
        }
        updateStatusItem()
    }

    // MARK: - Menu

    private func updateStatusItem() {
        if engineReloadPending, phase == .idle, !isWarming {
            engineReloadPending = false
            reloadEngine()
        }
        guard let button = statusItem.button else { return }
        let symbol: String
        if isDictating {
            symbol = "mic.fill"
        } else if phase == .recording(.listen) {
            symbol = "waveform"   // must look different from dictation: this one records other people
        } else if phase == .paused {
            symbol = "pause.circle"
        } else if !hotkeyStatus.isHealthy || !listenHotkeyStatus.isHealthy || !engineReady {
            symbol = "exclamationmark.triangle.fill"  // never look healthy when we aren't
        } else {
            symbol = "mic"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Spiel")
        button.image?.isTemplate = !(isRecording || phase == .paused)
        rebuildMenu(statusItem.menu ?? NSMenu())
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        switch hotkeyStatus {
        case .registered(let desc):
            menu.addItem(withTitle: "Hotkey: \(desc)\(settings.dictationMode == .hold ? " (hold to talk)" : "")", action: nil, keyEquivalent: "")
        case .failed(let desc, let reason):
            let item = NSMenuItem(
                title: "⚠︎ Hotkey \(desc) NOT active — \(reason)",
                action: #selector(retryHotkey), keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
            let alt = NSMenuItem(title: "Try F5 instead", action: #selector(useF5), keyEquivalent: "")
            alt.target = self
            menu.addItem(alt)
        case .unregistered:
            menu.addItem(withTitle: "Hotkey: not registered", action: nil, keyEquivalent: "")
        }
        switch listenHotkeyStatus {
        case .registered(let desc):
            menu.addItem(withTitle: "Listen: \(desc)", action: nil, keyEquivalent: "")
        case .failed(let desc, let reason):
            let item = NSMenuItem(
                title: "⚠︎ Listen hotkey \(desc) NOT active — \(reason)",
                action: #selector(retryListenHotkey), keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        case .unregistered:
            menu.addItem(withTitle: "Listen: not registered", action: nil, keyEquivalent: "")
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: engineReady ? "Engine: ready" : "Engine: loading…",
                     action: nil, keyEquivalent: "")
        let mic = AudioCapture.resolve(preferredUID: settings.microphone?.uid, preferredName: settings.microphone?.name,
                                       devices: AudioCapture.inputDevices())
        if let note = mic.note {
            menu.addItem(withTitle: "⚠︎ Mic: \(note) (\(AudioCapture.defaultInputDeviceName()))", action: nil, keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Mic: \(inputDeviceLabel()) — \(AudioCapture.microphoneAuthorization().rawValue)",
                         action: nil, keyEquivalent: "")
        }
        if TextInserter.isSecureInputEnabled() {
            let holder = secureInputHolderCached().map { " (held by \($0))" } ?? " (identifying holder…)"
            menu.addItem(withTitle: "⚠︎ Secure Input active\(holder) — ⌘V paste is blocked",
                         action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "    Text still goes to the clipboard; Accessibility insert is tried first",
                         action: nil, keyEquivalent: "")
        }
        if !TextInserter.hasAccessibilityPermission() {
            let item = NSMenuItem(title: "⚠︎ Accessibility NOT effective — click to prompt",
                                  action: #selector(grantAccessibility), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(withTitle: "    If Spiel is already ON in that list, remove it (−) and re-add — the entry belongs to an older build",
                         action: nil, keyEquivalent: "")
        }
        if let lastError {
            menu.addItem(withTitle: "Last error: \(lastError)", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Last dictation: \(lastOutcome ?? "none yet")", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Last session: \(lastSession ?? "none yet")", action: nil, keyEquivalent: "")
        let folderItem = NSMenuItem(title: "Open Transcripts Folder", action: #selector(openTranscriptsFolder), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)
        let vocabItem = NSMenuItem(title: "Edit Vocabulary…", action: #selector(editVocabulary), keyEquivalent: "")
        vocabItem.target = self
        menu.addItem(vocabItem)
        let historyItem = NSMenuItem(title: "History…", action: #selector(showHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)
        let copyLast = NSMenuItem(title: lastDictationText == nil ? "Copy Last Dictation (none yet)" : "Copy Last Dictation",
                                  action: lastDictationText == nil ? nil : #selector(copyLastDictation), keyEquivalent: "")
        copyLast.target = self
        menu.addItem(copyLast)
        // Off by default: the log holds every transcript verbatim, so it is only
        // written once the user asks for it. The checkmark IS the persisted state.
        let loggingItem = NSMenuItem(title: "Diagnostic Logging", action: #selector(toggleLogging), keyEquivalent: "")
        loggingItem.target = self
        loggingItem.state = DiagnosticLog.isEnabled ? .on : .off
        menu.addItem(loggingItem)
        let logExists = FileManager.default.fileExists(atPath: DiagnosticLog.url.path)
        let logItem = NSMenuItem(
            title: logExists ? "Open Log…" : "Open Log… (nothing written yet)",
            action: logExists ? #selector(openLog) : nil, keyEquivalent: ""
        )
        logItem.target = self
        menu.addItem(logItem)

        // The checkmark is read from macOS on every menu open, never from a stored
        // preference — a login item the user switched off in System Settings would
        // otherwise keep showing a tick while Spiel never launched.
        let launchState = LaunchAtLogin.state()
        let launchItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = launchState.isChecked ? .on : .off
        switch launchState {
        case .on, .off:
            if launchState.isChecked, let note = LaunchAtLogin.locationNote(bundlePath: Bundle.main.bundleURL.path) {
                menu.addItem(launchItem)
                menu.addItem(withTitle: "    \(note)", action: nil, keyEquivalent: "")
            } else {
                menu.addItem(launchItem)
            }
        case .requiresApproval:
            launchItem.title = "⚠︎ Open at Login is blocked in System Settings"
            launchItem.action = #selector(openLoginItemsSettings)
            menu.addItem(launchItem)
            menu.addItem(withTitle: "    Click to open Login Items — only you can switch it back on there",
                         action: nil, keyEquivalent: "")
        case .unavailable(let why):
            launchItem.title = "Open at Login — unavailable"
            launchItem.action = nil
            menu.addItem(launchItem)
            menu.addItem(withTitle: "    \(why)", action: nil, keyEquivalent: "")
        }

        menu.addItem(.separator())
        let toggleItem = NSMenuItem(
            title: isDictating ? "Stop Dictation" : "Start Dictation",
            action: #selector(menuToggle), keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)
        switch phase {
        case .recording(.listen):
            let pauseItem = NSMenuItem(title: "Pause Listening", action: #selector(menuPauseListen), keyEquivalent: "")
            pauseItem.target = self
            menu.addItem(pauseItem)
            let stopItem = NSMenuItem(title: "Stop Listening", action: #selector(menuToggleListen), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)
        case .paused:
            let resumeItem = NSMenuItem(title: "Resume Listening", action: #selector(menuResumeListen), keyEquivalent: "")
            resumeItem.target = self
            menu.addItem(resumeItem)
            let stopItem = NSMenuItem(title: "Stop Listening", action: #selector(menuToggleListen), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)
        default:
            let listenItem = NSMenuItem(title: "Start Listening", action: #selector(menuToggleListen), keyEquivalent: "")
            listenItem.target = self
            menu.addItem(listenItem)
        }
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let setupItem = NSMenuItem(title: "Setup…", action: #selector(showSetupFromMenu), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)
        let cliItem = NSMenuItem(title: "Install Command Line Tool…", action: #selector(installCommandLineTool), keyEquivalent: "")
        cliItem.target = self
        menu.addItem(cliItem)
        let help = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "Help")
        let diag = NSMenuItem(title: "Send Diagnostics…", action: #selector(sendDiagnostics), keyEquivalent: "")
        diag.target = self
        helpMenu.addItem(diag)
        help.submenu = helpMenu
        menu.addItem(help)
        let quit = NSMenuItem(title: "Quit Spiel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// Returns the cached holder if fresh; otherwise kicks off an off-main lookup
    /// and returns nil. The menu shows "identifying…" and the item is retitled in
    /// place when the answer lands.
    private func secureInputHolderCached() -> String? {
        if let c = secureHolderCache, Date().timeIntervalSince(c.at) < 10 { return c.value }
        guard !secureHolderLookupRunning else { return nil }
        secureHolderLookupRunning = true
        Task.detached { [weak self] in
            let holder = TextInserter.secureInputHolder()
            await MainActor.run {
                guard let self else { return }
                self.secureHolderLookupRunning = false
                self.secureHolderCache = (holder, Date())
                if let menu = self.statusItem.menu,
                   let item = menu.items.first(where: { $0.title.hasPrefix("⚠︎ Secure Input active") }) {
                    item.title = "⚠︎ Secure Input active\(holder.map { " (held by \($0))" } ?? " (holder unknown)") — ⌘V paste is blocked"
                }
            }
        }
        return nil
    }

    /// Opens Settings on the Vocabulary tab (2.4); the file itself is still one
    /// click away there (Show in Finder).
    @objc private func editVocabulary() {
        settingsModel.tab = .vocabulary
        showSettings()
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(DiagnosticLog.url)
    }

    /// Menu → Diagnostic Logging. Turning it ON writes a state snapshot first, so the
    /// file is worth reading without relaunching to get the launch lines back;
    /// turning it OFF writes one last line so the file's end explains why it stops.
    @objc private func toggleLogging() {
        let turningOn = !DiagnosticLog.isEnabled
        if turningOn {
            DiagnosticLog.setEnabled(true, persist: true)
            DiagnosticLog.write("logging turned ON by user — state snapshot follows")
            DiagnosticLog.write(stateSnapshot())
        } else {
            DiagnosticLog.write("logging turned OFF by user — nothing further will be written until it is turned on again")
            DiagnosticLog.flush()
            DiagnosticLog.setEnabled(false, persist: true)
        }
        updateStatusItem()
    }

    /// Everything the launch path would have logged, read now.
    private func stateSnapshot() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?"
        let hotkey: String
        switch hotkeyStatus {
        case .registered(let d): hotkey = d
        case .failed(let d, let why): hotkey = "\(d) NOT active — \(why)"
        case .unregistered: hotkey = "not registered"
        }
        let listenKey: String
        switch listenHotkeyStatus {
        case .registered(let d): listenKey = d
        case .failed(let d, let why): listenKey = "\(d) NOT active — \(why)"
        case .unregistered: listenKey = "not registered"
        }
        return "snapshot — Spiel \(version) pid \(ProcessInfo.processInfo.processIdentifier); "
            + "hotkey: \(hotkey) (\(settings.dictationMode.rawValue)); listen hotkey: \(listenKey); "
            + "engine: \(engineName) \(engineReady ? "ready" : "loading") (chosen: \(settings.engine.rawValue)); "
            + "microphone: \(AudioCapture.microphoneAuthorization().rawValue), input device: \(inputDeviceLabel()); "
            + "accessibility effective: \(TextInserter.hasAccessibilityPermission()); "
            + "secure input: \(TextInserter.isSecureInputEnabled()); "
            + "open at login: \(LaunchAtLogin.label(LaunchAtLogin.state())); "
            + "transcripts folder: \(TranscriptStore.defaultFolder.path); last session: \(lastSession ?? "none yet"); "
            + "last outcome: \(lastOutcome ?? "none yet"); last error: \(lastError ?? "none"); "
            + "signature: \(Self.signatureSummary())"
    }

    /// Menu → Open at Login. Reports the state macOS gives back AFTER the call,
    /// not the state we asked for: registration can fail (translocated copy, user
    /// approval revoked) and a menu that ticks itself optimistically would claim a
    /// login item that does not exist.
    @objc private func toggleLaunchAtLogin() {
        let want = LaunchAtLogin.state() != .on
        let (after, error) = LaunchAtLogin.setEnabled(want)
        if let error {
            lastError = "Open at Login: \(error)"
            Notifier.post(title: "Spiel could not change Open at Login", body: error)
        } else if want, case .on = after,
                  let note = LaunchAtLogin.locationNote(bundlePath: Bundle.main.bundleURL.path) {
            Notifier.post(title: "Spiel will open at login", body: note)
        } else if want, after != .on {
            // Asked for on, did not get on, and nothing threw — say so rather than
            // leaving a silently unticked box.
            lastError = "Open at Login did not take effect: \(LaunchAtLogin.label(after))"
        }
        updateStatusItem()
    }

    @objc private func openLoginItemsSettings() {
        NSWorkspace.shared.open(LaunchAtLogin.settingsURL)
    }

    @objc private func menuToggle() { toggle() }
    @objc private func menuToggleListen() { toggleListen() }
    @objc private func menuPauseListen() { pauseListening() }
    @objc private func menuResumeListen() { resumeListening() }
    @objc private func retryHotkey() {
        registerHotkey(.dictation, settings.dictationCombo)
    }
    /// F5 is the dictation fallback only; Listen has no fallback key. Since 2.4 the
    /// choice is saved like any Settings shortcut (Settings → Reset puts ⌘⇧D back).
    @objc private func useF5() {
        guard !settings.listenCombo.sameKeys(as: .f5) else {
            lastError = "F5 is already the Listen shortcut — pick another in Settings"
            updateStatusItem()
            return
        }
        if registerHotkey(.dictation, .f5).isHealthy { settings.dictationCombo = .f5 }
        refreshSettingsModel()
    }
    @objc private func retryListenHotkey() {
        registerHotkey(.listen, settings.listenCombo)
    }

    @objc private func grantAccessibility() {
        TextInserter.requestAccessibilityPermission()
        startAccessibilityPoll()
    }
}

// MARK: - 2.4: hotkeys from Settings, hold-to-talk, Settings / History / Diagnostics

extension AppDelegate: NSWindowDelegate {

    /// Registers `combo` for `id` with the right handlers. Dictation always gets a
    /// release handler; whether it acts is decided per event from the current mode,
    /// so switching modes needs no re-registration.
    @discardableResult
    fileprivate func registerHotkey(_ id: HotkeyManager.Id, _ combo: HotkeyManager.Combo) -> HotkeyManager.Status {
        switch id {
        case .dictation:
            return hotkeys.register(.dictation, combo,
                onTrigger: { [weak self] in Task { @MainActor in self?.dictationKeyDown() } },
                onRelease: { [weak self] in Task { @MainActor in self?.dictationKeyUp() } })
        case .listen:
            return hotkeys.register(.listen, combo) { [weak self] in Task { @MainActor in self?.toggleListen() } }
        }
    }

    fileprivate func dictationKeyDown() {
        guard settings.dictationMode == .hold else { toggle(); return }
        switch phase {
        case .idle:
            holdReleasePending = false
            start()
        case .recording(.dictation):
            break  // already held; a stray repeat must not stop it
        default:
            toggle()  // same refusals / ignores as toggle mode (Listen running, busy)
        }
    }

    fileprivate func dictationKeyUp() {
        guard settings.dictationMode == .hold else { return }
        switch phase {
        case .recording(.dictation): stop()
        case .starting(.dictation): holdReleasePending = true
        default: break
        }
    }

    /// What the log and menu call the input: the picked device, or the default.
    fileprivate func inputDeviceLabel() -> String {
        switch AudioCapture.resolve(preferredUID: settings.microphone?.uid, preferredName: settings.microphone?.name,
                                    devices: AudioCapture.inputDevices()) {
        case .systemDefault: return "\(AudioCapture.defaultInputDeviceName()) (system default)"
        case .device(let d): return d.name
        case .missing(_, let name): return "\(AudioCapture.defaultInputDeviceName()) (system default — \(name) not connected)"
        }
    }

    fileprivate func reloadEngine() {
        DiagnosticLog.write("engine change requested: \(settings.engine.rawValue) — reloading")
        session = nil
        engineReady = false
        updateStatusItem()
        refreshSettingsModel()
        Task {
            await self.warmUp()
            self.refreshSettingsModel()
        }
    }

    // MARK: History

    /// Called for every dictation that produced text, inserted or not — a failed
    /// insert is exactly when he needs it back. A dictation taken under Secure
    /// Input is NOT kept (it is plausibly a password; see `quotedForLog`).
    fileprivate func recordHistory(_ text: String, app: String?) {
        guard !secureInputSeenThisDictation else {
            DiagnosticLog.write("history: dictation not kept — Secure Input was active")
            return
        }
        lastDictationText = text
        guard settings.historyEnabled else { return }
        history.add(text: text, app: app)
        saveHistory()
    }

    fileprivate func saveHistory() {
        do {
            try history.save()
            historyModel.note = nil
        } catch {
            lastError = "history could not be saved: \(error.localizedDescription)"
            DiagnosticLog.write("history save FAILED: \(error)")
        }
        historyModel.history = history
    }

    @objc fileprivate func copyLastDictation() {
        guard let text = lastDictationText else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        DiagnosticLog.write("copied last dictation to the clipboard (\(text.count) chars)")
    }

    fileprivate func clearHistory() {
        history.clear()
        lastDictationText = nil
        do {
            try history.save()
        } catch {
            DiagnosticLog.write("history clear: save failed (\(error)) — removing the file")
            try? FileManager.default.removeItem(at: DictationHistory.defaultURL)
        }
        historyModel.history = history
        historyModel.selection = []
        DiagnosticLog.write("history cleared by user")
        updateStatusItem()
    }

    fileprivate func wireHistoryModel() {
        historyModel.history = history
        historyModel.enabled = settings.historyEnabled
        historyModel.onClear = { [weak self] in self?.clearHistory() }
        historyModel.onOpenSettings = { [weak self] in self?.showSettings() }
    }

    @objc fileprivate func showHistory() {
        historyModel.history = history
        historyModel.enabled = settings.historyEnabled
        let window = historyWindow ?? makeWindow(title: "Spiel History", view: HistoryView(model: historyModel),
                                                 size: NSSize(width: 600, height: 520), autosave: "SpielHistory")
        historyWindow = window
        present(window)
    }

    // MARK: Settings

    fileprivate func wireSettingsModel() {
        let m = settingsModel
        m.applyHotkey = { [weak self] id, combo in self?.applyHotkeyFromSettings(id, combo) }
        m.setHotkeysSuspended = { [weak self] on in
            self?.hotkeys.setSuspended(on)
            DiagnosticLog.write("hotkeys \(on ? "suspended while recording a shortcut" : "resumed")")
            self?.updateStatusItem()
        }
        m.setDictationMode = { [weak self] mode in
            self?.settings.dictationMode = mode
            DiagnosticLog.write("dictation mode → \(mode.rawValue)")
            self?.updateStatusItem()
        }
        m.setEngine = { [weak self] choice in
            guard let self else { return }
            self.settings.engine = choice
            if self.phase == .idle && !self.isWarming { self.reloadEngine() } else {
                self.engineReloadPending = true
                self.settingsModel.engineStatus = "Switches to \(choice.engineName) when the current session ends"
            }
        }
        m.setMicrophone = { [weak self] uid, name in
            guard let self else { return }
            self.settings.microphone = uid.map { ($0, name ?? $0) }
            DiagnosticLog.write("microphone → \(uid == nil ? "system default" : name ?? uid!) (applies from the next start)")
            self.updateStatusItem()
        }
        m.toggleOpenAtLogin = { [weak self] in self?.toggleLaunchAtLogin(); self?.refreshSettingsModel() }
        m.toggleDiagnosticLogging = { [weak self] in self?.toggleLogging(); self?.refreshSettingsModel() }
        m.setHistoryEnabled = { [weak self] on in
            guard let self else { return }
            self.settings.historyEnabled = on
            self.historyModel.enabled = on
            DiagnosticLog.write("history \(on ? "ON" : "OFF") (existing entries kept until cleared)")
        }
        m.clearHistory = { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "Clear dictation history?"
            alert.informativeText = "This deletes the \(self.history.entries.count) saved dictations from this Mac."
            alert.addButton(withTitle: "Clear")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            let run = { (r: NSApplication.ModalResponse) in if r == .alertFirstButtonReturn { self.clearHistory() } }
            if let w = self.settingsWindow { alert.beginSheetModal(for: w, completionHandler: run) } else { run(alert.runModal()) }
        }
        m.refresh = { [weak self] in self?.refreshSettingsModel() }
        refreshSettingsModel()
    }

    /// Tries `combo`; on failure the previous combo goes back and the reason is
    /// returned for the field. Persisted only once it is actually registered.
    fileprivate func applyHotkeyFromSettings(_ id: HotkeyManager.Id, _ combo: HotkeyManager.Combo) -> String? {
        let previous = id == .dictation ? settings.dictationCombo : settings.listenCombo
        quietHotkeyFailures = true
        defer { quietHotkeyFailures = false }
        let status = registerHotkey(id, combo)
        if case .failed(_, let reason) = status {
            registerHotkey(id, previous)
            DiagnosticLog.write("hotkey \(id) → \(combo.description) refused: \(reason); kept \(previous.description)")
            refreshSettingsModel()
            return "\(combo.description) could not be registered: \(reason). Kept \(previous.description)."
        }
        if id == .dictation { settings.dictationCombo = combo } else { settings.listenCombo = combo }
        DiagnosticLog.write("hotkey \(id) → \(combo.description)")
        refreshSettingsModel()
        updateStatusItem()
        return nil
    }

    fileprivate func refreshSettingsModel() {
        let m = settingsModel
        m.dictationCombo = hotkeys.combo(.dictation) ?? settings.dictationCombo
        m.listenCombo = hotkeys.combo(.listen) ?? settings.listenCombo
        m.dictationMode = settings.dictationMode
        m.engine = settings.engine
        if !engineReloadPending {
            m.engineStatus = isWarming || !engineReady && lastError == nil
                ? "Loading…"
                : engineReady ? "In use: \(engineName)\(lastError.map { " — \($0)" } ?? "")" : "Not loaded: \(lastError ?? "unknown")"
        }
        m.devices = AudioCapture.inputDevices()
        m.systemDefaultName = AudioCapture.defaultInputDeviceName()
        m.microphoneUID = settings.microphone?.uid ?? ""
        m.microphoneName = settings.microphone?.name ?? ""
        let launch = LaunchAtLogin.state()
        m.openAtLogin = launch.isChecked
        switch launch {
        case .requiresApproval: m.openAtLoginNote = "Blocked in System Settings → General → Login Items — only you can allow it there."
        case .unavailable(let why): m.openAtLoginNote = why
        default: m.openAtLoginNote = launch.isChecked ? LaunchAtLogin.locationNote(bundlePath: Bundle.main.bundleURL.path) : nil
        }
        m.diagnosticLogging = DiagnosticLog.isEnabled
        m.historyEnabled = settings.historyEnabled
    }

    @objc fileprivate func showSettings() {
        refreshSettingsModel()
        settingsModel.loadVocabulary()
        let window = settingsWindow ?? makeWindow(title: "Spiel Settings", view: SettingsView(model: settingsModel),
                                                  size: NSSize(width: 600, height: 820), autosave: "SpielSettings")
        settingsWindow = window
        present(window)
    }

    fileprivate func makeWindow<V: View>(title: String, view: V, size: NSSize, autosave: String) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = title
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.setFrameAutosaveName(autosave)
        return w
    }

    fileprivate func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing Settings mid-recording must give the hotkeys back.
        if (notification.object as? NSWindow) === settingsWindow { settingsModel.cancelRecording() }
        if (notification.object as? NSWindow) === setupWindow { setupClosed() }
    }

    /// An accessory app has no menu bar of its own, but key equivalents are routed
    /// through `NSApp.mainMenu` — without one, ⌘C/⌘V/⌘A/⌘Z do nothing in the
    /// vocabulary editor or the history search field, and ⌘W does not close.
    fileprivate func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let s = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        s.target = self
        appMenu.addItem(s)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Spiel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: Diagnostics

    /// Help → Send Diagnostics…: facts about the machine and the app, plus the
    /// redacted log tail, zipped where he chooses (default Desktop) and revealed.
    /// Never any transcript, history or vocabulary text — see `DiagnosticsBundle`.
    @objc fileprivate func sendDiagnostics() {
        Task {
            let facts = await diagnosticFacts()
            let stamp: String = {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy-MM-dd HHmm"
                return f.string(from: Date())
            }()
            let panel = NSSavePanel()
            panel.title = "Save Spiel Diagnostics"
            panel.message = "Contains app and system state and a redacted log — no dictated text, history or vocabulary."
            panel.nameFieldStringValue = "Spiel Diagnostics \(stamp).zip"
            panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            panel.allowedContentTypes = [.zip]
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("spiel-diag-\(UUID().uuidString)", isDirectory: true)
            let folder = staging.appendingPathComponent("Spiel Diagnostics \(stamp)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                DiagnosticLog.flush()
                try DiagnosticsBundle.write(facts: facts, logURL: DiagnosticLog.url, into: folder)
                try DiagnosticsBundle.zip(folder: folder, to: dest)
                DiagnosticLog.write("diagnostics saved to \(dest.path)")
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } catch {
                DiagnosticLog.write("diagnostics FAILED: \(error)")
                Notifier.post(title: "Spiel could not save diagnostics", body: "\(error.localizedDescription)")
            }
        }
    }

    fileprivate func hotkeyLine(_ st: HotkeyManager.Status) -> String {
        switch st {
        case .registered(let d): return "\(d) registered"
        case .failed(let d, let why): return "\(d) NOT active — \(why)"
        case .unregistered: return "not registered"
        }
    }

    fileprivate func diagnosticFacts() async -> [(String, String)] {
        let info = Bundle.main.infoDictionary
        let notif = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let notifText: String = {
            switch notif {
            case .authorized: return "authorized"
            case .denied: return "denied"
            case .notDetermined: return "not determined"
            case .provisional: return "provisional"
            case .ephemeral: return "ephemeral"
            @unknown default: return "unknown (\(notif.rawValue))"
            }
        }()
        let secure = TextInserter.isSecureInputEnabled()
        let holder: String? = secure ? await Task.detached { TextInserter.secureInputHolder() }.value : nil
        let models = await Task.detached { DiagnosticsBundle.modelInventory() }.value
        let vocabTerms = FileManager.default.fileExists(atPath: Glossary.userFileURL.path)
            ? "custom file present, \(Glossary.load().count) aliases loaded (contents not included)"
            : "built-in only (\(Glossary().count) aliases)"
        return [
            ("App version", "\(info?["CFBundleShortVersionString"] ?? "?") (build \(info?["CFBundleVersion"] ?? "?"))"),
            ("macOS", ProcessInfo.processInfo.operatingSystemVersionString),
            ("Chip", DiagnosticsBundle.chip()),
            ("Memory", ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)),
            ("Microphone permission", AudioCapture.microphoneAuthorization().rawValue),
            ("Accessibility trusted", "\(TextInserter.hasAccessibilityPermission())"),
            ("Notifications", notifText),
            ("Dictation hotkey", hotkeyLine(hotkeyStatus) + " — mode: \(settings.dictationMode.rawValue)"),
            ("Listen hotkey", hotkeyLine(listenHotkeyStatus)),
            ("Engine chosen", settings.engine.engineName),
            ("Engine in use", engineReady ? engineName : "not loaded"),
            ("Apple SpeechAnalyzer", AppleSpeechTranscriber.isAvailable ? "available" : "not available (needs macOS 26)"),
            ("Models on disk", models),
            ("Microphone chosen", settings.microphone.map { "\($0.name) (\($0.uid))" } ?? "system default"),
            ("Microphone resolved", inputDeviceLabel()),
            ("Input devices", AudioCapture.inputDevices().map(\.name).joined(separator: ", ")),
            ("Last dictation", lastOutcome ?? "none yet"),
            ("Last error", lastError ?? "none"),
            ("Secure Input", secure ? "ACTIVE — held by \(holder ?? "unknown")" : "off"),
            ("Diagnostic logging", DiagnosticLog.isEnabled ? "on" : "off"),
            ("Open at Login", LaunchAtLogin.label(LaunchAtLogin.state())),
            ("History", settings.historyEnabled ? "on" : "off"),
            ("Vocabulary", vocabTerms),
            // Quotes stripped: the report blanks quoted spans, and this one is not private.
            ("Signature", Self.signatureSummary().replacingOccurrences(of: "\"", with: "")),
        ]
    }
}

// MARK: - 2.5: first-run setup window, command-line tool

extension AppDelegate {

    /// Launch: open the setup window on a fresh install, mark it done silently for
    /// an upgrade that already has everything, otherwise the pre-2.5 launch path.
    fileprivate func decideSetupAtLaunch() async {
        let checklist = await currentChecklist()
        let decision = SetupChecklist.launchDecision(completed: settings.setupCompleted, checklist)
        DiagnosticLog.write("setup at launch: \(decision) (still to do: \(checklist.remaining.isEmpty ? "nothing" : checklist.remaining.joined(separator: ", ")))")
        switch decision {
        case .show:
            setupShownAtLaunch = true
            showSetup()
        case .markDone:
            settings.setupCompleted = true
            requestPermissionsAtLaunch()
        case .skip:
            requestPermissionsAtLaunch()
        }
    }

    fileprivate func currentChecklist() async -> SetupChecklist {
        SetupChecklist(microphone: AudioCapture.microphoneAuthorization(),
                       accessibility: TextInserter.hasAccessibilityPermission(),
                       notifications: await notificationState(),
                       modelOnDisk: SpeechModels.isDownloaded(settings.engine))
    }

    fileprivate func notificationState() async -> SetupChecklist.Notifications {
        // Unbundled (running out of .build) UNUserNotificationCenter throws; there
        // is nothing to ask for there, so it counts as answered.
        guard Bundle.main.bundleIdentifier != nil else { return .denied }
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .allowed
        }
    }

    @objc fileprivate func showSetupFromMenu() { showSetup() }

    fileprivate func showSetup() {
        let m = setupModel
        m.requestMicrophone = { [weak self] in
            Task { @MainActor in
                let granted = await AudioCapture.requestMicrophoneAccess()
                DiagnosticLog.write("setup: microphone prompt → \(granted ? "granted" : "denied")")
                self?.refreshSetupModel()
            }
        }
        m.requestAccessibility = { [weak self] in
            // The prompt call is what puts Spiel INTO the Accessibility list (so
            // there is a switch to turn on); the pane is where he turns it on.
            TextInserter.requestAccessibilityPermission()
            SetupModel.openPrivacyPane("Privacy_Accessibility")
            DiagnosticLog.write("setup: opened Accessibility settings")
            self?.refreshSetupModel()
        }
        m.requestNotifications = { [weak self] in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                DiagnosticLog.write("setup: notification prompt → \(granted ? "granted" : "denied")")
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshSetupModel() } }
            }
        }
        m.retryModel = { [weak self] in
            guard let self, !self.isWarming, self.phase == .idle else { return }
            DiagnosticLog.write("setup: model retry requested")
            self.reloadEngine()
        }
        m.done = { [weak self] in self?.setupWindow?.close() }
        refreshSetupModel()
        let window = setupWindow ?? makeWindow(title: "Set up Spiel", view: SetupView(model: m),
                                               size: NSSize(width: 620, height: 640), autosave: "SpielSetup")
        window.styleMask.remove(.resizable)
        // The window follows the view's height (an error message is taller than a tick).
        (window.contentView as? NSHostingView<SetupView>)?.sizingOptions = [.preferredContentSize]
        setupWindow = window
        present(window)
        setupPoll?.invalidate()
        // Accessibility grants do not notify the app, and the other two can change
        // in System Settings behind the window — so every second while it is open.
        setupPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSetupModel() }
        }
    }

    fileprivate func refreshSetupModel() {
        let m = setupModel
        m.microphone = AudioCapture.microphoneAuthorization()
        let ax = TextInserter.hasAccessibilityPermission()
        if ax && !m.accessibility && setupWindow?.isVisible == true {
            DiagnosticLog.write("setup: accessibility granted")
            accessibilityPoll?.invalidate()
            accessibilityPoll = nil
            updateStatusItem()
        }
        m.accessibility = ax
        m.engine = settings.engine
        m.mode = settings.dictationMode
        m.shortcut = hotkeys.combo(.dictation)?.description ?? settings.dictationCombo.description
        if case .failed(_, let why) = hotkeyStatus { m.shortcutProblem = why } else { m.shortcutProblem = nil }
        if case .downloading(let f, _, let files) = m.model {
            m.model = .downloading(fraction: f, bytes: SpeechModels.bytesOnDisk(settings.engine), files: files)
        }
        Task { @MainActor in
            let n = await self.notificationState()
            if self.setupModel.notifications != n { self.setupModel.notifications = n }
        }
    }

    /// FluidAudio's progress for the engine being loaded. Only the CHOSEN engine
    /// drives the bar; a fallback's own download is reported by the end state.
    fileprivate func noteModelProgress(_ p: ModelLoadProgress, choice: EngineChoice) {
        guard choice == settings.engine, isWarming else { return }
        // Callbacks queued on main can land after warm-up has already set the end
        // state; a late "compiling" must not turn a ready engine back into a spinner.
        switch setupModel.model {
        case .ready, .fallback, .failed: return
        default: break
        }
        if modelWasOnDisk {
            if case .compiling = p.phase { setupModel.model = .compiling }
            return
        }
        switch p.phase {
        case .listing:
            if case .checking = setupModel.model { return }
            setupModel.model = .checking
        case .downloading(let done, let total):
            let f = p.downloadFraction ?? 0
            // FluidAudio's last download event is 100 %; the load that follows
            // reports nothing, so that IS the start of compiling.
            if f >= 1 { setupModel.model = .compiling; return }
            let pct = Int((f * 100).rounded(.down))
            guard pct != lastModelPercent else { return }
            if lastModelPercent < 0 { DiagnosticLog.write("setup: downloading \(choice.engineName)") }
            lastModelPercent = pct
            var bytes: Int64 = 0
            if case .downloading(_, let b, _) = setupModel.model { bytes = b }
            setupModel.model = .downloading(fraction: f, bytes: bytes,
                                            files: total > 0 ? "\(done) of \(total) files" : nil)
        case .compiling:
            setupModel.model = .compiling
        }
    }

    fileprivate func setupClosed() {
        setupPoll?.invalidate()
        setupPoll = nil
        if !settings.setupCompleted {
            settings.setupCompleted = true
            DiagnosticLog.write("setup window closed — marked done (still to do: \(setupModel.remaining) step(s)); Setup… in the menu reopens it")
        }
        if setupShownAtLaunch {
            setupShownAtLaunch = false
            foldPermissionsAfterSetup()
        }
    }

    /// The setup window took over the launch-time permission requests. If he closes
    /// it with some unanswered, ask now — before any dictation, which is the rule —
    /// rather than on the first hotkey press. Accessibility is not re-prompted: he
    /// just closed the window that offers it, and the menu keeps a ⚠︎ item for it.
    fileprivate func foldPermissionsAfterSetup() {
        if AudioCapture.microphoneAuthorization() == .notDetermined {
            Task {
                let granted = await AudioCapture.requestMicrophoneAccess()
                DiagnosticLog.write("microphone permission prompt after setup → \(granted ? "granted" : "denied")")
            }
        }
        Task { @MainActor in
            if await self.notificationState() == .notDetermined { Notifier.requestAuthorization() }
        }
        if !TextInserter.hasAccessibilityPermission() { startAccessibilityPoll() }
    }

    // MARK: Command-line tool

    /// Menu → Install Command Line Tool…: `~/.local/bin/spiel` → the helper inside
    /// this bundle. Never sudo; /usr/local/bin is offered only when it is writable
    /// and ~/.local/bin is not on the shell's PATH.
    @objc fileprivate func installCommandLineTool() {
        let helper = CommandLineInstaller.helper(in: Bundle.main.bundleURL)
        Task { @MainActor in
            let path = await Task.detached { CommandLineInstaller.loginShellPATH() }.value
            let user = CommandLineInstaller.userBin, system = CommandLineInstaller.systemBin
            let userOnPath = path.map { CommandLineInstaller.isOnPath(user, path: $0) }
            let systemUsable = FileManager.default.isWritableFile(atPath: system.path)
                && (path.map { CommandLineInstaller.isOnPath(system, path: $0) } ?? false)
            let offerSystem = userOnPath == false && systemUsable

            let ask = NSAlert()
            ask.messageText = "Install the spiel command?"
            var info = "Creates \(user.path)/spiel, a link to the tool inside this copy of Spiel. No administrator password. If you move Spiel.app later, install again.\n\nThen: spiel transcribe meeting.m4a — see spiel --help."
            if userOnPath == false {
                info += "\n\n\(user.path) is not on your shell's PATH\(offerSystem ? " — /usr/local/bin is, and you can write to it" : ""), so after installing there you will need to add it (the next window shows the line)."
            } else if userOnPath == nil {
                info += "\n\nSpiel could not read your shell's PATH to check that \(user.path) is on it."
            }
            ask.informativeText = info
            ask.addButton(withTitle: "Install")
            if offerSystem { ask.addButton(withTitle: "Install in /usr/local/bin") }
            ask.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            let r = ask.runModal()
            let target: URL
            switch r {
            case .alertFirstButtonReturn: target = user
            case .alertSecondButtonReturn where offerSystem: target = system
            default: return
            }
            let result = NSAlert()
            do {
                let outcome = try CommandLineInstaller.install(helper: helper, into: target)
                let link: String
                switch outcome {
                case .installed(let p): link = p; result.messageText = "Installed spiel"
                case .alreadyInstalled(let p): link = p; result.messageText = "spiel is already installed"
                case .replaced(let p, let prev): link = p; result.messageText = "Updated spiel"
                    DiagnosticLog.write("cli: replaced link to \(prev)")
                }
                DiagnosticLog.write("cli: \(link) → \(helper.path)")
                var text = "\(link) → \(helper.path)\n\nTry: spiel --help"
                let onPath = target == system || userOnPath == true
                if !onPath {
                    text += "\n\n\(target.path) is not on your PATH\(userOnPath == nil ? " (could not check)" : ""). Add this line to ~/.zshrc, then open a new terminal:\n\nexport PATH=\"$HOME/.local/bin:$PATH\""
                    result.addButton(withTitle: "Copy Line")
                    result.addButton(withTitle: "OK")
                }
                result.informativeText = text
                if result.runModal() == .alertFirstButtonReturn, !onPath {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("export PATH=\"$HOME/.local/bin:$PATH\"", forType: .string)
                }
            } catch {
                DiagnosticLog.write("cli: install FAILED: \(error)")
                result.alertStyle = .warning
                result.messageText = "Could not install spiel"
                result.informativeText = "\(error)"
                result.runModal()
            }
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
