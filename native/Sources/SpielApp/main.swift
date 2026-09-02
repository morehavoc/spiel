import AppKit
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
    private var isRecording = false
    private var hotkeyStatus: HotkeyManager.Status = .unregistered
    private var lastError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItem()

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

    private func warmUp() async {
        let transcriber = ParakeetTranscriber()
        let s = DictationSession(transcriber: transcriber)
        do {
            try await s.prepare()
            await s.setEventHandler { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            self.session = s
            self.engineReady = true
            self.lastError = nil
        } catch {
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
            } catch {
                self.engineReady = false
                self.lastError = "no speech engine could load: \(error)"
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
        case .textReleased:
            panel.setStatus("Listening…")
        case .error(let e):
            lastError = e
        }
    }

    // MARK: - Recording

    private func toggle() {
        isRecording ? stop() : start()
    }

    private func start() {
        guard engineReady, let session else {
            Notifier.post(
                title: "Spiel is not ready",
                body: lastError ?? "the speech engine is still loading"
            )
            return
        }
        // Capture the target app BEFORE our panel appears.
        inserter.captureFrontmostApp()
        Task { await session.reset() }

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
                Task { @MainActor in self.panel.update(level: min(rms * 6, 1)) }
            }
        } catch {
            Notifier.post(title: "Spiel could not open the microphone", body: "\(error)")
            return
        }
        isRecording = true
        panel.show(status: "Listening…")
        updateStatusItem()
    }

    private func stop() {
        guard let session else { return }
        capture.stop()
        isRecording = false
        panel.setStatus("Finishing…")
        updateStatusItem()

        Task {
            let text = await session.finish()
            await MainActor.run {
                self.panel.hide()
                guard !text.isEmpty else { return }
                let outcome = self.inserter.insert(text)
                if !outcome.success {
                    Notifier.post(
                        title: "Spiel could not insert the text",
                        body: outcome.detail ?? "unknown reason — the text is on your clipboard"
                    )
                }
            }
        }
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

        let menu = NSMenu()

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
        if TextInserter.isSecureInputEnabled() {
            menu.addItem(withTitle: "⚠︎ Secure Input active — paste is blocked",
                         action: nil, keyEquivalent: "")
        }
        if !TextInserter.hasAccessibilityPermission() {
            let item = NSMenuItem(title: "⚠︎ Grant Accessibility…",
                                  action: #selector(grantAccessibility), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if let lastError {
            menu.addItem(withTitle: "Last error: \(lastError)", action: nil, keyEquivalent: "")
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

        statusItem.menu = menu
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
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
