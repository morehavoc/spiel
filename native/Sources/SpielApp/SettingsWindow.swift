import AppKit
import SpielCore
import SwiftUI

/// State behind the Settings window. The AppDelegate owns it and does the real
/// work through the closures (register hotkeys, reload the engine, write defaults);
/// the view only reads and asks.
@MainActor
final class SettingsModel: ObservableObject {
    enum Tab: Hashable { case general, vocabulary }
    @Published var tab: Tab = .general

    @Published var dictationCombo = HotkeyManager.Combo.defaultCombo
    @Published var listenCombo = HotkeyManager.Combo.listen
    @Published var dictationHotkeyNote: String?
    @Published var listenHotkeyNote: String?
    /// Which field is waiting for a keypress (global hotkeys are suspended meanwhile).
    @Published var recording: HotkeyManager.Id?

    @Published var dictationMode: DictationMode = .toggle
    @Published var engine: EngineChoice = .unified
    @Published var engineStatus = ""

    /// "" = system default.
    @Published var microphoneUID = ""
    @Published var microphoneName = ""
    @Published var devices: [AudioCapture.InputDevice] = []
    @Published var systemDefaultName = ""

    @Published var openAtLogin = false
    @Published var openAtLoginNote: String?
    @Published var diagnosticLogging = false
    @Published var historyEnabled = true

    @Published var vocabText = ""
    @Published var vocabSaved = ""
    @Published var vocabStatus = ""
    var vocabDirty: Bool { vocabText != vocabSaved }

    // Wired by the AppDelegate.
    var applyHotkey: (HotkeyManager.Id, HotkeyManager.Combo) -> String? = { _, _ in nil }
    var setHotkeysSuspended: (Bool) -> Void = { _ in }
    var setDictationMode: (DictationMode) -> Void = { _ in }
    var setEngine: (EngineChoice) -> Void = { _ in }
    var setMicrophone: (String?, String?) -> Void = { _, _ in }
    var toggleOpenAtLogin: () -> Void = {}
    var toggleDiagnosticLogging: () -> Void = {}
    var setHistoryEnabled: (Bool) -> Void = { _ in }
    var clearHistory: () -> Void = {}
    var refresh: () -> Void = {}

    func combo(_ id: HotkeyManager.Id) -> HotkeyManager.Combo { id == .dictation ? dictationCombo : listenCombo }

    func beginRecording(_ id: HotkeyManager.Id) {
        guard recording != id else { return }
        if recording == nil { setHotkeysSuspended(true) }
        recording = id
        setNote(id, nil)
    }

    func cancelRecording() {
        guard recording != nil else { return }
        recording = nil
        setHotkeysSuspended(false)
    }

    /// A key was pressed in a recorder field. Validation first (no registration is
    /// attempted for a combo that breaks the rules), then hotkeys come back and the
    /// new one is registered for real, so a combo another app owns fails HERE,
    /// visibly, rather than on the next launch.
    func recorded(_ id: HotkeyManager.Id, keyCode: UInt32, modifiers: UInt32) {
        let combo = HotkeyManager.Combo(keyCode: keyCode, modifiers: modifiers)
        let other: HotkeyManager.Id = id == .dictation ? .listen : .dictation
        recording = nil
        setHotkeysSuspended(false)
        if let why = HotkeyRules.validate(combo, otherCombo: self.combo(other),
                                          otherName: other == .listen ? "Listen" : "Dictation") {
            setNote(id, why)
            return
        }
        setNote(id, applyHotkey(id, combo))
    }

    func reset(_ id: HotkeyManager.Id) {
        cancelRecording()
        let def: HotkeyManager.Combo = id == .dictation ? .defaultCombo : .listen
        let other: HotkeyManager.Id = id == .dictation ? .listen : .dictation
        if let why = HotkeyRules.validate(def, otherCombo: combo(other), otherName: other == .listen ? "Listen" : "Dictation") {
            setNote(id, "cannot reset: \(why) — change that one first")
            return
        }
        setNote(id, applyHotkey(id, def))
    }

    private func setNote(_ id: HotkeyManager.Id, _ note: String?) {
        if id == .dictation { dictationHotkeyNote = note } else { listenHotkeyNote = note }
    }

    // MARK: Vocabulary

    func loadVocabulary(force: Bool = false) {
        guard force || !vocabDirty else { return }
        let url = Glossary.ensureUserFile()
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        vocabText = text
        vocabSaved = text
        vocabStatus = describeVocabulary(text)
    }

    func saveVocabulary() {
        let data = Data(vocabText.utf8)
        guard data.count <= Glossary.maxUserFileBytes else {
            vocabStatus = "Not saved: \(data.count / 1024) KB is over the \(Glossary.maxUserFileBytes / 1024) KB limit"
            return
        }
        do {
            try DictationHistory.atomicWrite(data, to: Glossary.userFileURL)
            vocabSaved = vocabText
            vocabStatus = "Saved — " + describeVocabulary(vocabText) + ". The next dictation uses it."
            DiagnosticLog.write("vocabulary saved from Settings (\(data.count) bytes)")
        } catch {
            vocabStatus = "Not saved: \(error.localizedDescription)"
        }
    }

    private func describeVocabulary(_ text: String) -> String {
        let n = Glossary.parse(text).count
        return "\(n) term\(n == 1 ? "" : "s") in \(Glossary.userFileURL.lastPathComponent)"
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView(selection: $model.tab) {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsModel.Tab.general)
            VocabularySettings(model: model)
                .tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
                .tag(SettingsModel.Tab.vocabulary)
        }
        .padding(12)
        .frame(minWidth: 560, minHeight: 600)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Shortcuts") {
                hotkeyRow("Dictation", id: .dictation, note: model.dictationHotkeyNote)
                hotkeyRow("Listen", id: .listen, note: model.listenHotkeyNote)
                Picker("Dictation shortcut", selection: Binding(
                    get: { model.dictationMode },
                    set: { model.dictationMode = $0; model.setDictationMode($0) }
                )) {
                    ForEach(DictationMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
            }
            Section("Microphone") {
                Picker("Input", selection: Binding(
                    get: { model.microphoneUID },
                    set: { uid in
                        model.microphoneUID = uid
                        let name = model.devices.first { $0.uid == uid }?.name
                        model.microphoneName = name ?? ""
                        model.setMicrophone(uid.isEmpty ? nil : uid, name)
                    }
                )) {
                    Text("System default (\(model.systemDefaultName))").tag("")
                    ForEach(model.devices, id: \.uid) { Text($0.name).tag($0.uid) }
                    if !model.microphoneUID.isEmpty, !model.devices.contains(where: { $0.uid == model.microphoneUID }) {
                        Text("\(model.microphoneName) (not connected)").tag(model.microphoneUID)
                    }
                }
                if !model.microphoneUID.isEmpty, !model.devices.contains(where: { $0.uid == model.microphoneUID }) {
                    Text("\(model.microphoneName) is not connected — Spiel is using the system default until it is.")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            Section("Speech engine") {
                Picker("Engine", selection: Binding(
                    get: { model.engine },
                    set: { model.engine = $0; model.setEngine($0) }
                )) {
                    ForEach(EngineChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text(model.engineStatus).font(.callout).foregroundStyle(.secondary)
            }
            Section("History") {
                Toggle("Keep the last \(DictationHistory.cap) dictations", isOn: Binding(
                    get: { model.historyEnabled },
                    set: { model.historyEnabled = $0; model.setHistoryEnabled($0) }
                ))
                HStack {
                    Text("Stored only on this Mac. Listen transcripts are saved separately.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History") { model.clearHistory() }
                }
            }
            Section("General") {
                Toggle("Open at Login", isOn: Binding(get: { model.openAtLogin }, set: { _ in model.toggleOpenAtLogin() }))
                if let note = model.openAtLoginNote {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                Toggle("Diagnostic Logging", isOn: Binding(get: { model.diagnosticLogging }, set: { _ in model.toggleDiagnosticLogging() }))
                Text("Writes ~/Library/Logs/Spiel.log, including dictated text. Off unless you are chasing a problem.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func hotkeyRow(_ title: String, id: HotkeyManager.Id, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                ShortcutRecorder(
                    label: model.recording == id ? "Press a shortcut… (esc cancels)" : model.combo(id).description,
                    isRecording: model.recording == id,
                    onStart: { model.beginRecording(id) },
                    onKey: { key, mods in model.recorded(id, keyCode: key, modifiers: mods) },
                    onCancel: { model.cancelRecording() }
                )
                .frame(width: 210, height: 24)
                Button("Reset") { model.reset(id) }
                    .disabled(model.combo(id) == (id == .dictation ? .defaultCombo : .listen))
            }
            if let note {
                Text(note).font(.callout).foregroundStyle(.red)
            }
        }
    }
}

private struct VocabularySettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("One term per line: the spelling you want, then how the engine tends to hear it.")
                .foregroundStyle(.secondary)
            Text("ArcGIS: arc gis, arc g i s").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            TextEditor(text: $model.vocabText)
                .font(.system(.body, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
            HStack {
                Text(model.vocabDirty ? "Unsaved changes" : model.vocabStatus)
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Glossary.ensureUserFile()])
                }
                Button("Revert") { model.loadVocabulary(force: true) }.disabled(!model.vocabDirty)
                Button("Save") { model.saveVocabulary() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.vocabDirty)
            }
        }
        .padding(8)
    }
}

/// "Click, then press your shortcut." An AppKit view because SwiftUI has no way to
/// see a raw key-down with ⌘ held: ⌘-combos arrive as key EQUIVALENTS, which the
/// window offers to the view hierarchy before the menu — so this view claims them
/// while recording and ⌘C cannot fire Copy instead of being recorded.
struct ShortcutRecorder: NSViewRepresentable {
    var label: String
    var isRecording: Bool
    var onStart: () -> Void
    var onKey: (UInt32, UInt32) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderView { RecorderView() }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.label = label
        view.isRecording = isRecording
        view.onStart = onStart
        view.onKey = onKey
        view.onCancel = onCancel
        if isRecording, view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
        view.needsDisplay = true
    }
}

final class RecorderView: NSView {
    var label = ""
    var isRecording = false
    var onStart: (() -> Void)?
    var onKey: ((UInt32, UInt32) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    /// One click, even when the Settings window is not yet key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onStart?()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        capture(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        capture(event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { onCancel?() }
        return super.resignFirstResponder()
    }

    private func capture(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53, flags.intersection([.command, .shift, .option, .control]).isEmpty {  // ⎋
            onCancel?()
            return
        }
        let mods = KeyNames.carbonModifiers(command: flags.contains(.command), shift: flags.contains(.shift),
                                            option: flags.contains(.option), control: flags.contains(.control))
        onKey?(UInt32(event.keyCode), mods)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Semantic colours resolve against this view's appearance while drawing, so
        // the field reads in light AND dark (2.3.2 shipped dark-on-dark buttons).
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: isRecording ? .regular : .medium),
            .foregroundColor: isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let s = NSAttributedString(string: label, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}
