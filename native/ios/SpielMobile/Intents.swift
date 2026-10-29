import AppIntents
import Foundation

/// Shortcuts action: the newest Spiel Listen transcript as Markdown text. A Shortcut
/// run when Listen stops uses this to read the transcript at any length, with nothing
/// going through the clipboard.
struct GetLatestTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Latest Spiel Transcript"
    static let description = IntentDescription(
        "Returns the most recent Spiel Listen transcript as Markdown text, header included.")
    static let openAppWhenRun = false

    enum Failure: Error, CustomLocalizedStringResourceConvertible {
        case none
        var localizedStringResource: LocalizedStringResource { "There are no Spiel transcripts yet." }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let latest = SavedTranscript.all().first,
              let text = try? String(contentsOf: latest.url, encoding: .utf8) else { throw Failure.none }
        return .result(value: text)
    }
}

struct SpielShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetLatestTranscriptIntent(),
                    phrases: ["Get the latest \(.applicationName) transcript"],
                    shortTitle: "Latest Transcript",
                    systemImageName: "doc.text")
    }
}
