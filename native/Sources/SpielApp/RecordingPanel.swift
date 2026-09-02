import AppKit
import Foundation

/// The floating "I'm listening" indicator.
///
/// CPU note, because this is where the old app spent it: the Electron recording bar
/// ran a `requestAnimationFrame` loop at ~60 Hz that called a Zustand setter on every
/// tick, re-rendering the whole React tree — status indicator, waveform and transcript
/// — inside a transparent, `backdrop-blur`, always-on-top window. Transparent blurred
/// always-on-top windows are the expensive case for the macOS compositor, and almost
/// none of that work was speech processing.
///
/// Here: a plain NSPanel, one custom view, `needsDisplay` set at **15 Hz**, and no
/// blur. Redraw is a handful of rounded rects.
final class RecordingPanel {
    private var panel: NSPanel?
    private var meterView: MeterView?
    private var lastDraw = Date.distantPast
    private static let redrawInterval: TimeInterval = 1.0 / 15.0

    func show(status: String) {
        if panel == nil { build() }
        meterView?.statusText = status
        panel?.orderFrontRegardless()
        meterView?.needsDisplay = true
    }

    func hide() { panel?.orderOut(nil) }

    func setStatus(_ text: String) {
        meterView?.statusText = text
        meterView?.needsDisplay = true
    }

    /// Live preview: the transcript so far, sentence by sentence as segments land.
    /// (Christopher, 2026-09-02: "show me a preview of the text in the popover as
    /// it is transcribing".) Segments are released when the VAD closes them, so the
    /// preview updates at the end of each phrase, not per word.
    func setTranscript(_ text: String) {
        meterView?.transcript = text
        meterView?.needsDisplay = true
    }

    /// Throttled on purpose — see the class comment.
    func update(level: Float) {
        guard let meterView else { return }
        meterView.push(level)
        let now = Date()
        guard now.timeIntervalSince(lastDraw) >= Self.redrawInterval else { return }
        lastDraw = now
        meterView.needsDisplay = true
    }

    private func build() {
        // Bigger on purpose (was 260×54 with 18 px bars): Christopher, 2026-09-02,
        // "sure would be nice if the little blue dots were bigger… barely noticeable".
        let width: CGFloat = 420, height: CGFloat = 150
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let rect = NSRect(
            x: screen.midX - width / 2,
            y: screen.maxY - height - 40,
            width: width, height: height
        )
        let p = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = MeterView(frame: NSRect(origin: .zero, size: rect.size))
        p.contentView = view
        meterView = view
        panel = p
    }
}

private final class MeterView: NSView {
    /// Longest word-aligned suffix of `text` that fits `rect` at `attrs`, with a
    /// leading ellipsis when anything was cut.
    static func tail(_ text: String, fitting rect: NSRect, attrs: [NSAttributedString.Key: Any]) -> String {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return text }
        func fits(_ start: Int) -> Bool {
            let s = (start > 0 ? "…" : "") + words[start...].joined(separator: " ")
            let r = NSAttributedString(string: s, attributes: attrs).boundingRect(
                with: NSSize(width: rect.width, height: 10_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
            return r.height <= rect.height
        }
        if fits(0) { return text }
        var lo = 1, hi = words.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if fits(mid) { hi = mid } else { lo = mid + 1 }
        }
        return "…" + words[lo...].joined(separator: " ")
    }

    var statusText: String = "Listening"
    var transcript: String = ""
    private static let meterHeight: CGFloat = 40
    private static let textTop: CGFloat = 62  // y where the text area ends (from bottom)
    private var levels: [Float] = Array(repeating: 0, count: 36)

    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(min(max(level, 0), 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor(calibratedWhite: 0.08, alpha: 0.92).setFill()
        bg.fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.75, alpha: 1),
        ]
        statusText.draw(at: NSPoint(x: 14, y: bounds.height - 22), withAttributes: attrs)

        // Transcript preview under the meter: tail of the text, wrapped, newest at the
        // bottom. Only the last few lines fit, so trim from the front by whole words.
        let textRect = NSRect(x: 14, y: 8, width: bounds.width - 28, height: Self.textTop - 8)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.95, alpha: 1),
        ]
        let shown = transcript.isEmpty ? "…" : Self.tail(transcript, fitting: textRect, attrs: textAttrs)
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byWordWrapping
        var attrs2 = textAttrs; attrs2[.paragraphStyle] = para
        let str = NSAttributedString(string: shown, attributes: attrs2)
        let h = min(str.boundingRect(with: NSSize(width: textRect.width, height: 10_000),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading]).height,
                    textRect.height)
        str.draw(with: NSRect(x: textRect.minX, y: textRect.maxY - h, width: textRect.width, height: h),
                 options: [.usesLineFragmentOrigin, .usesFontLeading])

        let barsRect = NSRect(x: 14, y: Self.textTop + 6, width: bounds.width - 28, height: Self.meterHeight)
        let barWidth = barsRect.width / CGFloat(levels.count) - 3
        NSColor(calibratedRed: 0.35, green: 0.78, blue: 0.98, alpha: 1).setFill()
        for (i, level) in levels.enumerated() {
            let h = max(4, CGFloat(level) * barsRect.height)
            let x = barsRect.minX + CGFloat(i) * (barWidth + 2)
            let bar = NSRect(x: x, y: barsRect.minY + (barsRect.height - h) / 2, width: barWidth, height: h)
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}
