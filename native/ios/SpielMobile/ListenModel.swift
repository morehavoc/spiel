import AVFoundation
import Foundation
import SwiftUI
import UIKit

/// One Listen session on the iPhone: mic → `DictationSession` (the Mac's VAD,
/// segmenting and ordering, unchanged) → `TranscriptDocument` → autosaved
/// Markdown in Documents/Spiel/Transcripts.
@MainActor
final class ListenModel: ObservableObject {
    enum Phase: Equatable {
        case loading(String)
        case ready
        case recording
        case paused
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

    private var session: DictationSession?
    private let capture = AudioCapture()
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0
    private var endedAt: Date?
    private var autosave: Timer?
    private var consecutiveFailures = 0
    private var observers: [NSObjectProtocol] = []
    private var interrupted = false

    var isActive: Bool { phase == .recording || phase == .paused }

    init() {
        observeAudioSession()
        Task { await loadEngine() }
    }

    // MARK: - Engine

    private func loadEngine() async {
        let transcriber = ParakeetTranscriber(version: .v3) { p in
            let text: String
            switch p.phase {
            case .listing: text = "Finding the speech model…"
            case .downloading:
                text = "Downloading the speech model (about 600 MB, once)… \(Int((p.downloadFraction ?? 0) * 100))%"
            case .compiling: text = "Preparing the speech model for the Neural Engine…"
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.noteLoading(text) } }
        }
        let s = DictationSession(transcriber: transcriber)
        do {
            try await s.prepare()
        } catch {
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
        phase = .ready
        #if DEBUG
        if ProcessInfo.processInfo.environment["SPIEL_AUTOSTART"] == "1" { start() }
        #endif
    }

    private func noteLoading(_ text: String) {
        if case .loading = phase { phase = .loading(text) }
    }

    // MARK: - Controls

    func start() {
        guard phase == .ready, let session else { return }
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                lastError = "Microphone access is off. Settings → Spiel → Microphone."
                return
            }
            await session.setGlossary(Glossary.load())
            await session.reset()
            doc = TranscriptDocument()
            revision += 1
            startedAt = Date()
            endedAt = nil
            fileURL = nil
            pausedTotal = 0
            consecutiveFailures = 0
            lastError = nil
            if title.isEmpty { title = "Meeting" }
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
        Task {
            let report = await session.finishWithReport()
            endedAt = report.endedAt
            if !report.errors.isEmpty { DiagnosticLog.write("listen ended with errors: \(report.diagnosis)") }
            save()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func openMic(into session: DictationSession) -> Bool {
        let sink = session.sink
        do {
            try capture.start { samples in sink.submit(samples) }
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
            if doc.paragraphs.count != before || !isActive { save() }
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
            inputDevice: AudioCapture.currentInputName, engine: "parakeet-tdt-0.6b-v3")
        do {
            try TranscriptStore.save(doc.render(frontmatter: fm), to: url, replacing: fileURL)
            fileURL = url
        } catch {
            lastError = "Autosave failed: \(error). Copy the text before closing."
            DiagnosticLog.write("autosave failed: \(error)")
        }
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
