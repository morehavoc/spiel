import AppKit
import SpielCore
import SwiftUI

/// State behind the License window (2.6, official build only). The AppDelegate
/// owns it and does the activation; the view only reads and asks.
@MainActor
final class LicenseModel: ObservableObject {
    @Published var key = ""
    @Published var status: LicensePolicy.Status = .trial(daysLeft: LicensePolicy.trialDays)
    /// Masked key this Mac holds, if any.
    @Published var activeKey: String?
    /// The last activation error, verbatim from `ActivationError.message`.
    @Published var message: String?
    @Published var working = false
    @Published var canBuy = false
    /// Licensed, but he asked to enter a different key.
    @Published var changingKey = false

    var activate: () -> Void = {}
    var buy: () -> Void = {}
    var close: () -> Void = {}

    /// Licensed and not changing the key: the window shows the key and Done, with no
    /// field and no Buy button (2.7.2 showed Buy as the only live button after activating).
    var showsLicensed: Bool { status == .licensed && activeKey != nil && !changingKey }

    var statusLine: String { LicensePolicy.menuLine(status) ?? "Licensed \(activeKey ?? "")" }
}

struct LicenseView: View {
    @ObservedObject var model: LicenseModel

    var body: some View {
        if model.showsLicensed { licensed } else { entry }
    }

    private var licensed: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Licensed \(model.activeKey ?? "")")
            } icon: {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
            .font(.headline)
            HStack {
                Spacer()
                Button("Change Key") { model.changingKey = true }
                Button("Done") { model.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.statusLine).foregroundStyle(.secondary)
            TextField("License key", text: $model.key)
                .textFieldStyle(.roundedBorder)
                .disabled(model.working)
                .onSubmit { model.activate() }
            if let message = model.message {
                Text(message).foregroundStyle(.red)
            }
            HStack {
                if model.working { ProgressView().controlSize(.small) }
                Spacer()
                if model.changingKey {
                    Button("Cancel") { model.changingKey = false; model.key = ""; model.message = nil }
                } else {
                    Button("Buy Spiel") { model.buy() }
                        .disabled(!model.canBuy)
                }
                Button("Activate") { model.activate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.working || model.key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
