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

    private func warmUp() async {
        let transcriber = ParakeetTranscriber()
        let s = DictationSession(transcriber: transcriber)
        let t0 = Date()
        do {
            try await s.prepare()
            await s.setEventHandler { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            self.session = s
            self.engineReady = true
            self.lastError = nil
            DiagnosticLog.write("engine ready: parakeet (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
        } catch {
            DiagnosticLog.write("parakeet failed to load: \(error) — trying Apple SpeechAnalyzer")
            // Fall back to Apple's on-device engine rather than dying. Parakeet needs
            // a HuggingFace download on first run; no network on first launch should
            // degrade the app, not brick it.
            let fallback = AppleSpeechTranscriber()
            let s2 = DictationSession(transcriber: fallback)
            do {
                try await s2.prepare()
                await s2.setEventHandler { [weak self] event in
                    Task { @MainActor in self?.handle(event) }
                }
                self.session = s2
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
        // Capture the target app BEFORE our panel appears.
        inserter.captureFrontmostApp()
        DiagnosticLog.write("start: target app = \(inserter.capturedAppName ?? "?"), input device = \(AudioCapture.defaultInputDeviceName()), secure input = \(TextInserter.isSecureInputEnabled())")
        // reset() re-arms the audio path and must complete BEFORE the mic starts
        // submitting, or the first buffers land in a disarmed sink. It is awaited,
        // not blocked on: the main actor stays free (menu, hotkey, UI), and a press
        // that lands in the gap is ignored by `toggle()` via `phase`.
        phase = .starting
        updateStatusItem()
        Task {
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

    private func stop() {
        guard let session, phase == .recording else { return }
        capture.stop()
        phase = .finishing
        panel.setStatus("Finishing…")
        updateStatusItem()
        Task {
            let report = await session.finishWithReport()
            await MainActor.run {
                self.panel.hide()
                self.phase = .idle
                self.deliver(report)
            }
        }
    }

    /// Every dictation ends with ONE line saying what happened — inserted where and
    /// how, or exactly why not. An empty transcript used to `return` silently here,
    /// which made "the mic gave us nothing", "no speech detected" and "paste blocked"
    /// all look identical from the outside: a panel that disappears and no text.
    private func deliver(_ report: DictationSession.Report) {
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
            DiagnosticLog.write("finish: \(lastOutcome!) — \"\(report.text)\"")
        } else {
            let why = outcome.detail ?? "unknown reason — the text is on your clipboard"
            lastOutcome = "could not insert into \(target): \(why)"
            DiagnosticLog.write("finish: INSERT FAILED into \(target): \(why) — text: \"\(report.text)\"")
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
        let logItem = NSMenuItem(title: "Open Log…", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

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

    @objc private func openLog() {
        NSWorkspace.shared.open(DiagnosticLog.url)
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
