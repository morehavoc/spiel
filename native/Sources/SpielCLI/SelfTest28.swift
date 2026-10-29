import Foundation
import SpielCore

/// 2.8 — "Run a Shortcut when Listen stops".
extension SelfTest {

    static func tests28() async {
        print("\n2.8.3 — Help menu links")
        expect(SpielLinks.help.absoluteString, "https://morehavoc.com/spiel/", "Spiel Help opens the help site")
        expect(SpielLinks.supportMail(version: "2.8.3 (17)").absoluteString,
               "mailto:spiel@christophermoravec.com?subject=Spiel%202.8.3%20(17)", "Email Support names the version in the subject")

        print("\n2.8 — Shortcut when Listen stops")
        let file = URL(fileURLWithPath: "/tmp/My Meeting 2026-10-27.md")
        expect(ListenShortcut.arguments(name: "Send to Jaws", file: file).joined(separator: "|"),
               "run|Send to Jaws|--input-path|/tmp/My Meeting 2026-10-27.md",
               "the transcript FILE is the input, the name and path passed as single arguments (spaces intact)")

        let suite = "spiel-selftest-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let s = SpielSettings(defaults: d)
        expect(s.listenStopShortcut ?? "nil", "nil", "off by default")
        s.listenStopShortcut = "  Send to Jaws "
        expect(s.listenStopShortcut ?? "nil", "Send to Jaws", "stored trimmed")
        s.listenStopShortcut = "   "
        expect(s.listenStopShortcut ?? "nil", "nil", "blank clears it")
        s.listenStopShortcut = "X"; s.listenStopShortcut = nil
        expect(s.listenStopShortcut ?? "nil", "nil", "None clears it")

        if FileManager.default.isExecutableFile(atPath: ListenShortcut.tool.path) {
            let r = ListenShortcut.runSync(ListenShortcut.arguments(name: "spiel-selftest-no-such-shortcut-\(UUID().uuidString)", file: file), timeout: 30)
            expect(!r.ok && !r.timedOut ? "failed" : "ok=\(r.ok) timedOut=\(r.timedOut)", "failed",
                   "a missing Shortcut is reported as a failure, not success (exit \(r.status): \(r.stderr.prefix(80)))")
        } else {
            print("  – SKIPPED: /usr/bin/shortcuts not present (nothing asserted)")
        }

        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        var main: String?
        for _ in 0..<8 {
            if let m = try? String(contentsOf: dir.appendingPathComponent("Sources/SpielApp/main.swift"), encoding: .utf8) { main = m; break }
            dir.deleteLastPathComponent()
        }
        guard let main, let start = main.range(of: "private func deliverTranscript("),
              let end = main.range(of: "private func copyListen()", range: start.upperBound..<main.endIndex) else {
            print("  – SKIPPED: Sources/SpielApp/main.swift not found beside this binary (nothing asserted)")
            return
        }
        let body = String(main[start.lowerBound..<end.lowerBound])
        let save = body.range(of: "saveListen()"), run = body.range(of: "runListenStopShortcut()")
        expect(save != nil && run != nil && save!.lowerBound < run!.lowerBound ? "ok" : "missing/out of order", "ok",
               "the Shortcut runs on every stop, after the final save (it gets the finished file)")
    }
}
