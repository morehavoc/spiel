import AppKit
import SpielCore
import SwiftUI

/// State behind the first-run setup window (2.5). The AppDelegate owns it: it
/// polls the permissions while the window is open and pushes the engine's real
/// load progress in; the view only reads and asks.
@MainActor
final class SetupModel: ObservableObject {
    enum ModelState: Equatable {
        /// Warm-up has not reported yet (or FluidAudio is listing files).
        case checking
        /// `fraction` is FluidAudio's download fraction (see `ModelLoadProgress`);
        /// nil when it has not given one yet. `bytes` is what is on disk so far.
        case downloading(fraction: Double?, bytes: Int64, files: String?)
        /// Downloaded; CoreML is compiling it. No fraction exists for this.
        case compiling
        case ready(engine: String, bytes: Int64)
        /// Loaded, but not the engine he chose — the chosen one failed.
        case fallback(using: String, error: String)
        case failed(String)
    }

    @Published var microphone: AudioCapture.MicrophoneAuthorization = .notDetermined
    @Published var accessibility = false
    @Published var notifications: SetupChecklist.Notifications = .notDetermined
    @Published var model: ModelState = .checking
    @Published var engine: EngineChoice = .unified
    @Published var shortcut = HotkeyManager.Combo.defaultCombo.description
    @Published var shortcutProblem: String?
    @Published var mode: DictationMode = .toggle

    var requestMicrophone: () -> Void = {}
    var requestAccessibility: () -> Void = {}
    var requestNotifications: () -> Void = {}
    var retryModel: () -> Void = {}
    var done: () -> Void = {}

    var modelSatisfied: Bool { if case .ready = model { return true }; return false }
    var remaining: Int {
        [microphone == .authorized, accessibility, notifications != .notDetermined, modelSatisfied].filter { !$0 }.count
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
    static func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.morehavoc.spiel"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set up Spiel").font(.title).bold()
                Text("Spiel turns your speech into text in any app, entirely on this Mac. Each step ticks itself off as soon as it is done. You can close this window at any time and reopen it with Setup… in the Spiel menu.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 14)

            VStack(spacing: 0) {
                microphoneRow
                Divider()
                accessibilityRow
                Divider()
                notificationsRow
                Divider()
                modelRow
                Divider()
                tryItRow
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))

            HStack {
                Text(model.remaining == 0 ? "All set." : "\(model.remaining) step\(model.remaining == 1 ? "" : "s") left — Spiel still works for whatever is done.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(model.remaining == 0 ? "Done" : "Finish Later") { model.done() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .padding(20)
        .frame(width: 620)
    }

    // MARK: Rows

    private var microphoneRow: some View {
        StepRow(number: 1, title: "Microphone", status: microphoneStatus,
                detail: microphoneDetail) {
            switch model.microphone {
            case .authorized: EmptyView()
            case .notDetermined: Button("Allow Microphone…") { model.requestMicrophone() }
            case .denied, .restricted:
                Button("Open Privacy Settings") { SetupModel.openPrivacyPane("Privacy_Microphone") }
            }
        }
    }
    private var microphoneStatus: StepStatus {
        switch model.microphone {
        case .authorized: return .done
        case .notDetermined: return .todo
        case .denied, .restricted: return .problem
        }
    }
    private var microphoneDetail: String {
        switch model.microphone {
        case .authorized: return "Allowed. Audio is transcribed on this Mac and never recorded to disk."
        case .notDetermined: return "So Spiel can hear you. Audio is transcribed on this Mac and never leaves it."
        case .denied: return "Microphone access is off, so dictation cannot hear anything. Turn Spiel on under Privacy & Security → Microphone."
        case .restricted: return "Microphone access is restricted on this Mac (a profile or parental control) — Spiel cannot change that."
        }
    }

    private var accessibilityRow: some View {
        StepRow(number: 2, title: "Accessibility", status: model.accessibility ? .done : .todo,
                detail: model.accessibility
                    ? "Allowed. Dictated text is typed straight into the app you are using."
                    : "So Spiel can type the text into other apps. Without it the text lands on the clipboard and you paste it yourself. Turn Spiel on in the list that opens — this step ticks itself within a second. If Spiel is already on there but this stays unticked, that entry belongs to an older copy: remove it with − and add it again.") {
            if !model.accessibility {
                Button("Open Accessibility Settings") { model.requestAccessibility() }
            }
        }
    }

    private var notificationsRow: some View {
        StepRow(number: 3, title: "Notifications", status: {
            switch model.notifications {
            case .allowed: return .done
            case .notDetermined: return .todo
            case .denied: return .optionalOff
            }
        }(), detail: {
            switch model.notifications {
            case .allowed: return "Allowed. Spiel only notifies when something needs you."
            case .notDetermined: return "So Spiel can tell you when something goes wrong — a shortcut another app took, a microphone that stopped."
            case .denied: return "Off. Spiel still works, but problems only show in its menu. You can turn them on in System Settings → Notifications."
            }
        }()) {
            switch model.notifications {
            case .allowed: EmptyView()
            case .notDetermined: Button("Allow Notifications…") { model.requestNotifications() }
            case .denied: Button("Open Notification Settings") { SetupModel.openNotificationSettings() }
            }
        }
    }

    private var modelTitle: String { "Speech model — \(SpeechModels.displayName(model.engine))" }

    private var modelRow: some View {
        StepRow(number: 4, title: modelTitle, status: modelStatus, detail: modelDetail) {
            switch model.model {
            case .failed, .fallback: Button("Retry") { model.retryModel() }
            default: EmptyView()
            }
        } extra: {
            modelProgress
        }
    }

    private var modelStatus: StepStatus {
        switch model.model {
        case .ready: return .done
        case .checking, .downloading, .compiling: return .working
        case .fallback: return .optionalOff
        case .failed: return .problem
        }
    }

    private var sizeNote: String {
        SpeechModels.approximateMB(model.engine).map { "about \($0) MB, downloaded once from Hugging Face and kept on this Mac" }
            ?? "managed by macOS, downloaded by the system the first time it is used"
    }

    private var modelDetail: String {
        switch model.model {
        case .checking: return "Looking for the model (\(sizeNote))…"
        case .downloading: return "Downloading — \(sizeNote). Spiel keeps working on other steps meanwhile."
        case .compiling: return "On this Mac (\(sizeNote.hasPrefix("about") ? "downloaded" : "managed by macOS")). Loading it onto the Neural Engine — the first time after a download takes longest."
        case .ready(let engine, let bytes):
            return "Ready — \(engine)\(bytes > 0 ? ", \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) on disk" : ""). Nothing leaves this Mac when you dictate."
        case .fallback(let using, let error):
            return "\(SpeechModels.displayName(model.engine)) could not load, so Spiel is using \(using) for now. Check the internet connection, then Retry.\nError: \(error)"
        case .failed(let error):
            return "Download failed — check the internet connection, then Retry. No speech engine is loaded, so dictation cannot work yet.\nError: \(error)"
        }
    }

    @ViewBuilder
    private var modelProgress: some View {
        switch model.model {
        case .downloading(let fraction, let bytes, let files):
            VStack(alignment: .leading, spacing: 3) {
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text([
                    "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) downloaded",
                    fraction.map { "\(Int(($0 * 100).rounded(.down)))%" },
                    files,
                ].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .checking, .compiling:
            ProgressView().progressViewStyle(.linear)
        default:
            EmptyView()
        }
    }

    private var tryItRow: some View {
        StepRow(number: 5, title: "Try it", status: .info, detail: tryItText) { EmptyView() }
    }
    private var tryItText: String {
        if let problem = model.shortcutProblem { return "The dictation shortcut is not active: \(problem). Pick another in Settings." }
        switch model.mode {
        case .toggle: return "Click into any text field, press \(model.shortcut), say something, then press \(model.shortcut) again. The text appears where your cursor is."
        case .hold: return "Click into any text field, hold \(model.shortcut) while you talk, and let go. The text appears where your cursor is."
        }
    }
}

enum StepStatus { case done, todo, working, problem, optionalOff, info }

/// One numbered step: status mark, title, explanation, and the button that fixes it.
private struct StepRow<Action: View, Extra: View>: View {
    let number: Int
    let title: String
    let status: StepStatus
    let detail: String
    @ViewBuilder let action: () -> Action
    @ViewBuilder let extra: () -> Extra

    init(number: Int, title: String, status: StepStatus, detail: String,
         @ViewBuilder action: @escaping () -> Action, @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }) {
        self.number = number; self.title = title; self.status = status; self.detail = detail
        self.action = action; self.extra = extra
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            mark.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(status == .problem ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                extra()
            }
            Spacer(minLength: 8)
            action()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder private var mark: some View {
        switch status {
        case .done: Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
        case .todo: numberBadge
        case .working: ProgressView().controlSize(.small)
        case .problem: Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.red)
        case .optionalOff: Image(systemName: "exclamationmark.circle.fill").font(.title2).foregroundStyle(.orange)
        case .info: Image(systemName: "keyboard").font(.title3).foregroundStyle(.secondary)
        }
    }

    private var numberBadge: some View {
        ZStack {
            Circle().stroke(Color.secondary, lineWidth: 1.5)
            Text("\(number)").font(.callout).bold().foregroundStyle(.secondary)
        }
    }
}
