import AppKit
import Foundation
import SpielCore

/// The Listen sidebar: a tall, narrow, always-on-top panel at the right edge of the
/// screen with an editable title, a level meter, a running counter and the transcript
/// growing paragraph by paragraph, newest at the bottom. Designed for glancing at
/// from the chair during a meeting, not for editing.
///
/// Why not `RecordingPanel`: that one is a 420×150 meter whose `tail()` binary
/// search re-lays out the whole string on every change — fine for a sentence,
/// a real cost at 60,000 characters. This panel holds the text in an `NSTextView`
/// and only ever touches the paragraph that changed, plus the one or two whose
/// age just crossed the recency threshold.
///
/// Rules (design §4c): never a modal, never activates the app, never steals focus.
/// The one keyboard interaction is the title field, and only when clicked.
@MainActor
final class ListenPanel {

    var onTitleChanged: ((String) -> Void)?
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    var onStop: (() -> Void)?
    var onCopy: (() -> Void)?
    var onOpen: (() -> Void)?

    /// Text newer than this is full brightness; older is dimmed.
    static let recentSeconds: TimeInterval = 30
    static let width: CGFloat = 380
    static let edgeInset: CGFloat = 12

    private var panel: KeyablePanel?
    private var titleField: NSTextField!
    private var meter: LevelBars!
    private var counterLabel: NSTextField!
    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private var newestPill: NSButton!
    private var pauseButton: NSButton!
    private var stopButton: NSButton!
    private var copyButton: NSButton!
    private var openButton: NSButton!
    private var doneButton: NSButton!
    private var summaryLabel: NSTextField!
    private var titleDelegate: TitleDelegate!

    private var doc = TranscriptDocument()
    /// What is currently rendered, per paragraph: its text-storage range and
    /// whether it has been dimmed. Kept so an append touches one range.
    private var rendered: [(text: String, range: NSRange, dimmed: Bool)] = []
    private var autoScroll = true
    private var tintTimer: Timer?
    private var lastMeterDraw = Date.distantPast
    private var isDone = false
    private var copiedResetWork: DispatchWorkItem?

    private static let bodyFont = NSFont.systemFont(ofSize: 16)
    private static let stampFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private static let bright = NSColor(calibratedWhite: 0.96, alpha: 1)
    private static let dim = NSColor(calibratedWhite: 0.70, alpha: 1)
    private static let stampColor = NSColor(calibratedWhite: 0.55, alpha: 1)
    private static let markerColor = NSColor(calibratedRed: 0.95, green: 0.75, blue: 0.35, alpha: 1)

    // MARK: - Lifecycle

    /// A new session: reset everything, show the panel in the live state.
    func begin(title: String, document: TranscriptDocument) {
        if panel == nil { build() }
        isDone = false
        autoScroll = true
        titleField.stringValue = title
        titleField.placeholderString = "Untitled"
        summaryLabel.isHidden = true
        counterLabel.isHidden = false
        meter.isHidden = false
        pauseButton.isHidden = false
        pauseButton.title = "Pause"
        stopButton.isHidden = false
        copyButton.isHidden = true
        openButton.isHidden = true
        doneButton.isHidden = true
        newestPill.isHidden = true
        pauseButton.isEnabled = true
        stopButton.isEnabled = true
        rendered.removeAll()
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        setDocument(document)
        place()
        panel?.orderFrontRegardless()
        tintTimer?.invalidate()
        tintTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.retint() }
        }
    }

    func setPaused(_ paused: Bool) {
        pauseButton.title = paused ? "Resume" : "Pause"
    }

    func setFinishing() {
        pauseButton.isEnabled = false
        stopButton.isEnabled = false
        counterLabel.stringValue = "Finishing…"
    }

    /// The top bar swaps to the summary and Copy / Open / Done; the body stays.
    func setDone(summary: String, document: TranscriptDocument) {
        isDone = true
        setDocument(document)
        tintTimer?.invalidate(); tintTimer = nil
        // Everything reads as "past" once the session is over.
        for i in rendered.indices where !rendered[i].dimmed { applyTint(index: i, dimmed: true) }
        summaryLabel.stringValue = summary
        summaryLabel.isHidden = false
        counterLabel.isHidden = true
        meter.isHidden = true
        pauseButton.isHidden = true
        stopButton.isHidden = true
        copyButton.isHidden = false
        copyButton.title = "Copy"
        openButton.isHidden = false
        doneButton.isHidden = false
        panel?.orderFrontRegardless()
    }

    func hide() {
        tintTimer?.invalidate(); tintTimer = nil
        panel?.orderOut(nil)
    }

    var title: String { titleField?.stringValue ?? "" }

    func setCounter(elapsed: TimeInterval, words: Int, paused: Bool) {
        let mins = Int(elapsed) / 60, secs = Int(elapsed) % 60
        let state = paused ? "Paused" : "Listening"
        counterLabel.stringValue = "\(state) · \(String(format: "%d:%02d", mins, secs)) · \(words.formatted()) words"
    }

    func flashCopied() {
        copyButton.title = "Copied"
        copiedResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.copyButton.title = "Copy" }
        copiedResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Throttled to 15 Hz like `RecordingPanel`; the audio thread calls this often.
    func update(level: Float) {
        guard let meter, !meter.isHidden else { return }
        meter.push(level)
        let now = Date()
        guard now.timeIntervalSince(lastMeterDraw) >= 1.0 / 15.0 else { return }
        lastMeterDraw = now
        meter.needsDisplay = true
    }

    // MARK: - Transcript rendering

    /// Renders the difference between `doc` and what is on screen. The common case
    /// — the last paragraph grew, or one was appended — touches one range. Anything
    /// else (a marker inserted, a pause correction shifting offsets) rebuilds.
    func setDocument(_ newDoc: TranscriptDocument) {
        doc = newDoc
        guard let storage = textView.textStorage else { return }
        let paragraphs = newDoc.paragraphs
        let common = rendered.count
        let incremental: Bool = {
            guard paragraphs.count >= common else { return false }
            guard common > 0 else { return true }
            // Every already-rendered paragraph except the last must be unchanged.
            for i in 0..<(common - 1) where Self.line(paragraphs[i]) != rendered[i].text { return false }
            return true
        }()
        guard incremental else {
            rebuild(storage, paragraphs)
            return
        }
        storage.beginEditing()
        if common > 0 {
            let newLast = Self.line(paragraphs[common - 1])
            if newLast != rendered[common - 1].text {
                // The newest paragraph grew: replace just its range. It is the last
                // range in the storage, so nothing after it shifts.
                let old = rendered[common - 1]
                let attributed = Self.attributed(paragraphs[common - 1], dimmed: false)
                storage.replaceCharacters(in: old.range, with: attributed)
                rendered[common - 1] = (newLast, NSRange(location: old.range.location, length: attributed.length), false)
            }
        }
        for i in common..<paragraphs.count {
            let sep = storage.length == 0 ? "" : "\n\n"
            let start = storage.length + sep.utf16.count
            let attributed = Self.attributed(paragraphs[i], dimmed: false)
            storage.append(NSAttributedString(string: sep, attributes: [.font: Self.bodyFont]))
            storage.append(attributed)
            rendered.append((Self.line(paragraphs[i]), NSRange(location: start, length: attributed.length), false))
        }
        storage.endEditing()
        if autoScroll { textView.scrollToEndOfDocument(nil) }
    }

    private func rebuild(_ storage: NSTextStorage, _ paragraphs: [TranscriptDocument.Paragraph]) {
        rendered.removeAll()
        let out = NSMutableAttributedString()
        let now = Date()
        for (i, p) in paragraphs.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n\n", attributes: [.font: Self.bodyFont])) }
            let dimmed = isDone || now.timeIntervalSince(p.appendedAt) > Self.recentSeconds
            let a = Self.attributed(p, dimmed: dimmed)
            rendered.append((Self.line(p), NSRange(location: out.length, length: a.length), dimmed))
            out.append(a)
        }
        storage.setAttributedString(out)
        if autoScroll { textView.scrollToEndOfDocument(nil) }
    }

    /// The identity of a rendered paragraph: offset + text, so a pause correction
    /// that shifts an offset counts as a change.
    private static func line(_ p: TranscriptDocument.Paragraph) -> String {
        p.isMarker ? p.text : "[\(TranscriptDocument.formatOffset(p.offset))] \(p.text)"
    }

    private static func attributed(_ p: TranscriptDocument.Paragraph, dimmed: Bool) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.lineSpacing = 2
        if p.isMarker {
            return NSAttributedString(string: p.text, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: markerColor, .paragraphStyle: para,
            ])
        }
        let s = NSMutableAttributedString(string: "[\(TranscriptDocument.formatOffset(p.offset))] ", attributes: [
            .font: stampFont, .foregroundColor: stampColor, .paragraphStyle: para,
        ])
        s.append(NSAttributedString(string: p.text, attributes: [
            .font: bodyFont, .foregroundColor: dimmed ? dim : bright, .paragraphStyle: para,
        ]))
        return s
    }

    /// Once a second: dim paragraphs whose age just crossed the threshold. Walks
    /// back from the newest and stops at the first already-dimmed one, so the
    /// work is one or two paragraphs, never the whole storage.
    private func retint() {
        let now = Date()
        var i = rendered.count - 1
        while i >= 0, !rendered[i].dimmed {
            if now.timeIntervalSince(doc.paragraphs[i].appendedAt) > Self.recentSeconds {
                applyTint(index: i, dimmed: true)
            }
            i -= 1
        }
    }

    private func applyTint(index i: Int, dimmed: Bool) {
        guard let storage = textView.textStorage, i < rendered.count, i < doc.paragraphs.count else { return }
        let p = doc.paragraphs[i]
        rendered[i].dimmed = dimmed
        guard !p.isMarker else { return }
        let stampLength = "[\(TranscriptDocument.formatOffset(p.offset))] ".utf16.count
        let r = rendered[i].range
        guard r.length > stampLength, r.location + r.length <= storage.length else { return }
        storage.addAttribute(.foregroundColor, value: dimmed ? Self.dim : Self.bright,
                             range: NSRange(location: r.location + stampLength, length: r.length - stampLength))
    }

    // MARK: - Building

    private func place() {
        guard let p = panel else { return }
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let height = (screen.height * 0.6).rounded()
        let origin = NSPoint(x: screen.maxX - Self.width - Self.edgeInset,
                             y: screen.midY - height / 2)
        p.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)
    }

    private func build() {
        let size = NSSize(width: Self.width, height: 600)
        let p = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        // The panel paints its own dark background, so its controls must render in
        // dark appearance too. Under a light system appearance the buttons drew dark
        // labels on a dark bezel — Pause/Stop illegible (Christopher, 2026-09-25).
        p.appearance = NSAppearance(named: .darkAqua)
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true

        let root = RoundedDarkView(frame: NSRect(origin: .zero, size: size))
        root.autoresizingMask = [.width, .height]
        p.contentView = root

        // Top bar ---------------------------------------------------------
        let title = NSTextField(frame: .zero)
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.textColor = Self.bright
        title.backgroundColor = .clear
        title.isBordered = false
        title.focusRingType = .none
        title.placeholderString = "Untitled"
        title.lineBreakMode = .byTruncatingTail
        title.cell?.usesSingleLineMode = true
        titleDelegate = TitleDelegate { [weak self] text in self?.onTitleChanged?(text) }
        title.delegate = titleDelegate
        titleField = title

        let bars = LevelBars(frame: .zero)
        meter = bars

        let counter = Self.label(size: 12, color: Self.dim)
        counter.stringValue = "Listening · 0:00 · 0 words"
        counterLabel = counter

        let summary = Self.label(size: 12, color: Self.dim)
        summary.isHidden = true
        summaryLabel = summary

        // Body ------------------------------------------------------------
        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: Self.width - 32, height: 100))
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isRichText = true
        tv.textContainerInset = NSSize(width: 4, height: 8)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: Self.width - 32, height: .greatestFiniteMagnitude)
        tv.font = Self.bodyFont
        scroll.documentView = tv
        textView = tv
        scrollView = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled() }
        }

        let pill = NSButton(title: "↓ newest", target: nil, action: nil)
        pill.bezelStyle = .inline
        pill.controlSize = .small
        pill.isHidden = true
        pill.target = self
        pill.action = #selector(jumpToNewest)
        newestPill = pill

        // Bottom bar ------------------------------------------------------
        pauseButton = Self.button("Pause", target: self, action: #selector(pauseTapped))
        stopButton = Self.button("Stop", target: self, action: #selector(stopTapped))
        copyButton = Self.button("Copy", target: self, action: #selector(copyTapped))
        openButton = Self.button("Open", target: self, action: #selector(openTapped))
        doneButton = Self.button("Done", target: self, action: #selector(doneTapped))
        stopButton.keyEquivalent = ""

        for v in [title, bars, counter, summary, scroll, pill, pauseButton, stopButton, copyButton, openButton, doneButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let m: CGFloat = 14
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),

            bars.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            bars.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            bars.widthAnchor.constraint(equalToConstant: 84),
            bars.heightAnchor.constraint(equalToConstant: 16),

            counter.centerYAnchor.constraint(equalTo: bars.centerYAnchor),
            counter.leadingAnchor.constraint(equalTo: bars.trailingAnchor, constant: 10),
            counter.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),

            summary.centerYAnchor.constraint(equalTo: bars.centerYAnchor),
            summary.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            summary.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),

            scroll.topAnchor.constraint(equalTo: bars.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m - 4),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -(m - 4)),
            scroll.bottomAnchor.constraint(equalTo: pauseButton.topAnchor, constant: -10),

            pill.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -6),
            pill.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),

            pauseButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            pauseButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            stopButton.leadingAnchor.constraint(equalTo: pauseButton.trailingAnchor, constant: 8),
            stopButton.bottomAnchor.constraint(equalTo: pauseButton.bottomAnchor),

            copyButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            copyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            openButton.leadingAnchor.constraint(equalTo: copyButton.trailingAnchor, constant: 8),
            openButton.bottomAnchor.constraint(equalTo: copyButton.bottomAnchor),
            doneButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            doneButton.bottomAnchor.constraint(equalTo: copyButton.bottomAnchor),
        ])
        panel = p
    }

    private static func label(size: CGFloat, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    private static func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = NSFont.systemFont(ofSize: 12)
        return b
    }

    // MARK: - Scrolling

    private func scrolled() {
        guard let scrollView, let textView else { return }
        let visible = scrollView.contentView.bounds
        let distanceFromBottom = textView.frame.maxY - visible.maxY
        let atBottom = distanceFromBottom <= 40
        if atBottom != autoScroll {
            autoScroll = atBottom
            newestPill.isHidden = atBottom
        }
    }

    @objc private func jumpToNewest() {
        autoScroll = true
        newestPill.isHidden = true
        textView.scrollToEndOfDocument(nil)
    }

    @objc private func pauseTapped() {
        if pauseButton.title == "Pause" { onPause?() } else { onResume?() }
    }
    @objc private func stopTapped() { onStop?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func openTapped() { onOpen?() }
    @objc private func doneTapped() { hide() }
}

/// A borderless, non-activating panel that can still take keyboard focus for the
/// title field. `nonactivatingPanel` means becoming key does NOT activate Spiel,
/// so Teams stays frontmost.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class RoundedDarkView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
        bg.fill()
    }
}

/// Twelve bars, same drawing idea as `RecordingPanel`'s meter, small enough to
/// sit beside the counter.
private final class LevelBars: NSView {
    private var levels: [Float] = Array(repeating: 0, count: 12)
    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(min(max(level, 0), 1))
    }
    override func draw(_ dirtyRect: NSRect) {
        let barWidth = bounds.width / CGFloat(levels.count) - 2
        NSColor(calibratedRed: 0.35, green: 0.78, blue: 0.98, alpha: 1).setFill()
        for (i, level) in levels.enumerated() {
            let h = max(3, CGFloat(level) * bounds.height)
            let x = CGFloat(i) * (barWidth + 2)
            let r = NSRect(x: x, y: (bounds.height - h) / 2, width: barWidth, height: h)
            NSBezierPath(roundedRect: r, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}

/// Reports the title on every edit end (Return or focus loss), so the file on
/// disk follows the title.
private final class TitleDelegate: NSObject, NSTextFieldDelegate {
    private let onChange: (String) -> Void
    init(onChange: @escaping (String) -> Void) { self.onChange = onChange }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        onChange(field.stringValue)
    }
}
