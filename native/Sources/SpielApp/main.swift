import AppKit
import AVFoundation
import Foundation
import SpielCore

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
    private enum Phase { case idle, starting, recording, finishing }
    private var phase: Phase = .idle
    private var isRecording: Bool { phase == .recording }
    /// Secure Input holder lookup shells out to `ioreg`; cache it and resolve it off
    /// the main thread so opening the menu never stalls.
    private var secureHolderCache: (value: String?, at: Date)?
    private var secureHolderLookupRunning = false
    private var hotkeyStatus: HotkeyManager.Status = .unregistered
    private var lastError: String?
    /// What the last dictation did, in one line. Lives in the menu because the menu
    /// is the only surface the user actually opens when "nothing happened".
    private var lastOutcome: String?
    /// Running transcript for the panel preview; reset on every start.
    private var previewText = ""
    private var accessibilityPoll: Timer?

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

        // Ask for every permission at LAUNCH, not on the first hotkey press. The first
        // test build asked for the mic on the first ⌘⇧D, which meant the entire first
        // dictation was spent looking at a TCC dialog while the engine ran on silence,
        // and asked for notification permission only when it first had something to
        // say — so that first message was lost too.
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

        hotkeys.setStatusHandler { [weak self] status in
            Task { @MainActor in
                self?.hotkeyStatus = status
                self?.updateStatusItem()
            }
        }
        hotkeys.register(.defaultCombo) { [weak self] in
            Task { @MainActor in self?.toggle() }
        }

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

    private func warmUp() async {
        let t0 = Date()
        do {
            self.session = try await makeSession(ParakeetTranscriber())
            self.engineReady = true
            self.lastError = nil
            DiagnosticLog.write("engine ready: parakeet (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
        } catch {
            DiagnosticLog.write("parakeet failed to load: \(error) — trying Apple SpeechAnalyzer")
            // Fall back to Apple's on-device engine rather than dying. Parakeet needs
            // a HuggingFace download on first run; no network on first launch should
            // degrade the app, not brick it.
            do {
                self.session = try await makeSession(AppleSpeechTranscriber())
                self.engineReady = true
                self.lastError = "Parakeet unavailable, using Apple SpeechAnalyzer"
                DiagnosticLog.write("engine ready: apple SpeechAnalyzer (fallback)")
            } catch {
                self.engineReady = false
                self.lastError = "no speech engine could load: \(error)"
                DiagnosticLog.write("NO engine could load: \(error)")
            }
        }
        updateStatusItem()
    }

    private func handle(_ event: DictationSession.Event) {
        switch event {
        case .speechStarted:
            panel.setStatus("Listening…")
        case .segmentCaptured:
            panel.setStatus("Transcribing…")
        case .textReleased(let t):
            previewText = previewText.isEmpty ? t : previewText + " " + t
            panel.setTranscript(TranscriptAssembler.tidy(previewText))
            panel.setStatus("Listening…")
        case .error(let e):
            lastError = e
            DiagnosticLog.write("segment error: \(e)")
        }
    }

    // MARK: - Recording

    private func toggle() {
        switch phase {
        case .idle: start()
        case .recording: stop()
        case .starting, .finishing:
            DiagnosticLog.write("hotkey ignored: dictation is \(phase == .starting ? "starting" : "finishing")")
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
        DiagnosticLog.write("start: target app = \(inserter.capturedAppName ?? "?"), input device = \(AudioCapture.defaultInputDeviceName()), secure input = \(secureAtStart), vocabulary = \(glossary.count) aliases")
        // reset() re-arms the audio path and must complete BEFORE the mic starts
        // submitting, or the first buffers land in a disarmed sink. It is awaited,
        // not blocked on: the main actor stays free (menu, hotkey, UI), and a press
        // that lands in the gap is ignored by `toggle()` via `phase`.
        phase = .starting
        updateStatusItem()
        Task {
            // One task, in order: two separate Tasks against the same actor have no
            // ordering guarantee between them, and a glossary swap that landed after
            // reset() would still work but one that landed after the first segment's
            // release would apply the OLD vocabulary to that segment's preview.
            await session.setGlossary(glossary)
            await session.reset()
            await MainActor.run { self.beginCapture(session) }
        }
    }

    private func beginCapture(_ session: DictationSession) {
        guard phase == .starting else { return }
        do {
            try capture.start { [weak self] samples in
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
                Task { @MainActor in self.panel.update(level: level) }
            }
        } catch {
            DiagnosticLog.write("microphone failed to start: \(error)")
            lastOutcome = "microphone failed to start: \(error)"
            Notifier.post(title: "Spiel could not open the microphone", body: "\(error)")
            phase = .idle
            updateStatusItem()
            return
        }
        phase = .recording
        previewText = ""
        panel.setTranscript("")
        panel.show(status: "Listening…")
        updateStatusItem()
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
        guard let session, phase == .recording else { return }
        capture.stop()
        phase = .finishing
        panel.setStatus("Finishing…")
        updateStatusItem()
        finishGeneration += 1
        let generation = finishGeneration
        Task {
            let report = await session.finishWithReport()
            await MainActor.run {
                // A finish that comes back after the watchdog already replaced the
                // session is stale: its text would be delivered into whatever he is
                // doing now, a minute later.
                guard self.finishGeneration == generation, self.phase == .finishing else {
                    DiagnosticLog.write(
                        "stale finish ignored (watchdog already fired) — text was: "
                            + self.quotedForLog(report.text),
                        sensitive: true
                    )
                    return
                }
                self.panel.hide()
                self.phase = .idle
                self.deliver(report)
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: Self.finishWatchdogSeconds * 1_000_000_000)
            await MainActor.run {
                guard self.finishGeneration == generation, self.phase == .finishing else { return }
                let msg = "the speech engine did not return within \(Self.finishWatchdogSeconds)s — reloading it; that dictation is lost"
                DiagnosticLog.write("WATCHDOG: \(msg)")
                self.panel.hide()
                self.phase = .idle
                self.lastOutcome = msg
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
        if outcome.success {
            lastOutcome = "inserted \(report.text.split(separator: " ").count) words into \(target) via \(outcome.method.rawValue) (\(report.diagnosis))"
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
        guard let button = statusItem.button else { return }
        let symbol: String
        if isRecording {
            symbol = "mic.fill"
        } else if !hotkeyStatus.isHealthy || !engineReady {
            symbol = "exclamationmark.triangle.fill"  // never look healthy when we aren't
        } else {
            symbol = "mic"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Spiel")
        button.image?.isTemplate = !isRecording
        rebuildMenu(statusItem.menu ?? NSMenu())
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        switch hotkeyStatus {
        case .registered(let desc):
            menu.addItem(withTitle: "Hotkey: \(desc)", action: nil, keyEquivalent: "")
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

        menu.addItem(.separator())
        menu.addItem(withTitle: engineReady ? "Engine: ready" : "Engine: loading…",
                     action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Mic: \(AudioCapture.defaultInputDeviceName()) — \(AudioCapture.microphoneAuthorization().rawValue)",
                     action: nil, keyEquivalent: "")
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
        let vocabItem = NSMenuItem(title: "Edit Vocabulary…", action: #selector(editVocabulary), keyEquivalent: "")
        vocabItem.target = self
        menu.addItem(vocabItem)
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
            title: isRecording ? "Stop Dictation" : "Start Dictation",
            action: #selector(menuToggle), keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
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

    @objc private func editVocabulary() {
        let url = Glossary.ensureUserFile()
        DiagnosticLog.write("opening vocabulary file \(url.path)")
        NSWorkspace.shared.open(url)
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
        return "snapshot — Spiel \(version) pid \(ProcessInfo.processInfo.processIdentifier); "
            + "hotkey: \(hotkey); engine: \(engineReady ? "ready" : "loading"); "
            + "microphone: \(AudioCapture.microphoneAuthorization().rawValue), input device: \(AudioCapture.defaultInputDeviceName()); "
            + "accessibility effective: \(TextInserter.hasAccessibilityPermission()); "
            + "secure input: \(TextInserter.isSecureInputEnabled()); "
            + "open at login: \(LaunchAtLogin.label(LaunchAtLogin.state())); "
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
    @objc private func retryHotkey() {
        hotkeys.register(.defaultCombo) { [weak self] in
            Task { @MainActor in self?.toggle() }
        }
    }
    @objc private func useF5() {
        hotkeys.register(.f5) { [weak self] in
            Task { @MainActor in self?.toggle() }
        }
    }
    @objc private func grantAccessibility() {
        TextInserter.requestAccessibilityPermission()
        startAccessibilityPoll()
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
