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
    /// Optional (2.7): only Listen screenshots need it, so it never counts in `remaining`.
    @Published var screenRecording = false
    @Published var model: ModelState = .checking
    @Published var engine: EngineChoice = .unified
    @Published var shortcut = HotkeyManager.Combo.defaultCombo.description
    @Published var shortcutProblem: String?
    @Published var mode: DictationMode = .toggle

    var requestMicrophone: () -> Void = {}
    var requestAccessibility: () -> Void = {}
    var requestNotifications: () -> Void = {}
    var requestScreenRecording: () -> Void = {}
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
            }
            .padding(.bottom, 14)

            VStack(spacing: 0) {
                microphoneRow
                Divider()
                accessibilityRow
                Divider()
                notificationsRow
                Divider()
                screenRecordingRow
                Divider()
                modelRow
                Divider()
                tryItRow
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))

            HStack {
                Spacer()
                Button(model.remaining == 0 ? "Done" : "Later") { model.done() }
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
        case .authorized, .notDetermined: return ""
        case .denied: return "Turn Spiel on in Privacy & Security → Microphone."
        case .restricted: return "Blocked by a profile on this Mac."
        }
    }

    private var accessibilityRow: some View {
        StepRow(number: 2, title: "Accessibility", status: model.accessibility ? .done : .todo,
                detail: model.accessibility
                    ? ""
                    : "Lets Spiel type into other apps. If Spiel is already on in the list, remove it with − and add it again.") {
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
            case .allowed: return ""
            case .notDetermined: return "Only used when something goes wrong."
            case .denied: return "Off. Problems show in the Spiel menu instead."
            }
        }()) {
            switch model.notifications {
            case .allowed: EmptyView()
            case .notDetermined: Button("Allow Notifications…") { model.requestNotifications() }
            case .denied: Button("Open Notification Settings") { SetupModel.openNotificationSettings() }
            }
        }
    }

    private var screenRecordingRow: some View {
        StepRow(number: 4, title: "Screen Recording", status: model.screenRecording ? .done : .todo,
                detail: model.screenRecording ? "" : "Optional. For screenshots in Listen.") {
            if !model.screenRecording {
                Button("Open Screen Recording Settings") { model.requestScreenRecording() }
            }
        }
    }

    private var modelTitle: String { "Speech model" }

    private var modelRow: some View {
        StepRow(number: 5, title: modelTitle, status: modelStatus, detail: modelDetail) {
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
        SpeechModels.approximateMB(model.engine).map { "about \($0) MB" } ?? "provided by macOS"
    }

    private var modelDetail: String {
        switch model.model {
        case .checking: return "Checking…"
        case .downloading: return "Downloading \(SpeechModels.displayName(model.engine)), \(sizeNote)."
        case .compiling: return "Preparing. The first time can take a minute."
        case .ready(let engine, _): return engine
        case .fallback(let using, let error):
            return "\(SpeechModels.displayName(model.engine)) didn't load. Using \(using).\n\(error)"
        case .failed(let error):
            return "Download failed. Check your connection.\n\(error)"
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
        StepRow(number: 6, title: "Try it", status: .info, detail: tryItText) { EmptyView() }
    }
    private var tryItText: String {
        if let problem = model.shortcutProblem { return "\(model.shortcut) isn't working: \(problem). Change it in Settings." }
        switch model.mode {
        case .toggle: return "Press \(model.shortcut), talk, press it again."
        case .hold: return "Hold \(model.shortcut) and talk."
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
                if !detail.isEmpty {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(status == .problem ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                }
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
