import Foundation

/// TEMPORARY (0.5.3, 2026-11-20): on Christopher's iPhone a meeting started before the
/// speech model was ready stopped producing text partway through, and the saved
/// transcript was missing it too. The simulator does not reproduce it. This writes one
/// line every 30 s of a meeting so the diagnostics log shows where the audio stops:
/// at the mic, before the model, inside the model, or between the model and the
/// document. Remove it once that is known. Counts only, never transcript text.
@MainActor
final class MeetingHealth {
    private var timer: Timer?
    private var speechStarts = 0
    private var segments = 0
    private var texts = 0
    private var errors = 0
    private var loudest: Float = 0

    /// Calls `tick` every 30 s until `stop()`.
    func start(_ tick: @escaping @MainActor () -> Void) {
        stop()
        takeWindow()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func note(_ event: DictationSession.Event) {
        switch event {
        case .speechStarted: speechStarts += 1
        case .segmentCaptured: segments += 1
        case .textReleased: texts += 1
        case .error: errors += 1
        }
    }

    func noteLevel(_ level: Float) { loudest = max(loudest, level) }

    /// This window's counts as text, then zeroed for the next one.
    @discardableResult
    func takeWindow() -> String {
        defer { speechStarts = 0; segments = 0; texts = 0; errors = 0; loudest = 0 }
        return "loudest \(String(format: "%.2f", loudest)), speech starts \(speechStarts), segments \(segments), texts \(texts), errors \(errors)"
    }
}
