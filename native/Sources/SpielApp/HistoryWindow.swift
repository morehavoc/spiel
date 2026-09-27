import AppKit
import SpielCore
import SwiftUI

/// The History window's state. The AppDelegate owns the store and pushes entries in.
@MainActor
final class HistoryModel: ObservableObject {
    @Published var history = DictationHistory()
    @Published var enabled = true
    @Published var note: String?
    @Published var query = ""
    @Published var selection: Set<UUID> = []
    @Published var copiedID: UUID?
    /// Lives here, not in `@State`: SwiftUI's `@State` is a macro now, and the
    /// Command Line Tools ship no SwiftUIMacros plugin to expand it.
    @Published var confirmClear = false

    var onClear: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    var visible: [DictationHistory.Entry] { history.search(query) }

    func copy(_ ids: Set<UUID>) {
        // Several selected rows copy in the order they are listed (newest first).
        let chosen = visible.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(chosen.map(\.text).joined(separator: "\n\n"), forType: .string)
        copiedID = chosen.first?.id
        let flashed = copiedID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if self.copiedID == flashed { self.copiedID = nil }
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search dictations", text: $model.query)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(10)
            Divider()
            if !model.enabled && model.history.entries.isEmpty {
                empty("History is off", "Turn it on in Settings → History to keep your last \(DictationHistory.cap) dictations.",
                      action: ("Open Settings", model.onOpenSettings))
            } else if model.history.entries.isEmpty {
                empty("No dictations yet", model.note ?? "Each dictation that produces text is kept here, newest first.", action: nil)
            } else if model.visible.isEmpty {
                empty("No matches", "Nothing in the last \(model.history.entries.count) dictations matches “\(model.query)”.", action: nil)
            } else {
                List(model.visible, selection: $model.selection) { e in
                    row(e).tag(e.id)
                }
                .contextMenu(forSelectionType: UUID.self, menu: { ids in
                    Button("Copy") { model.copy(ids) }
                }, primaryAction: { ids in
                    model.copy(ids)   // double-click
                })
            }
            Divider()
            HStack {
                Text(footer).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Clear History…") { model.confirmClear = true }
                    .disabled(model.history.entries.isEmpty)
                Button("Copy") { model.copy(model.selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selection.isEmpty)
            }
            .padding(10)
        }
        .frame(minWidth: 520, minHeight: 420)
        .alert("Clear dictation history?", isPresented: $model.confirmClear) {
            Button("Clear", role: .destructive) { model.onClear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the \(model.history.entries.count) saved dictations from this Mac.")
        }
    }

    private var footer: String {
        if !model.enabled { return "History is off — nothing new is being saved" }
        return "Double-click or Copy puts the text on the clipboard"
    }

    private func row(_ e: DictationHistory.Entry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(e.text).lineLimit(3).textSelection(.disabled)
            HStack(spacing: 6) {
                Text(Self.stamp.string(from: e.date))
                Text("·")
                Text(e.app ?? "unknown app")
                Text("·")
                Text("\(e.words) word\(e.words == 1 ? "" : "s")")
                if model.copiedID == e.id {
                    // .primary, not the accent colour: the row being copied is usually the
                    // SELECTED row, whose background IS the accent colour.
                    Label("Copied", systemImage: "checkmark").foregroundStyle(.primary).fontWeight(.semibold)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func empty(_ title: String, _ body: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Text(title).font(.title3).fontWeight(.semibold)
            Text(body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            if let action { Button(action.0, action: action.1) }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
