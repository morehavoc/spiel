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

    var activate: () -> Void = {}
    var buy: () -> Void = {}

    var statusLine: String { LicensePolicy.menuLine(status) ?? "Licensed \(activeKey ?? "")" }
}

struct LicenseView: View {
    @ObservedObject var model: LicenseModel

    var body: some View {
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
                Button("Buy Spiel") { model.buy() }
                    .disabled(!model.canBuy)
                Button("Activate") { model.activate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.working || model.key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
