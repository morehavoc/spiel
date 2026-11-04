import Foundation
import SpielCore

/// 2.8 — "Run a Shortcut when Listen stops".
extension SelfTest {

    static func tests29() async {
        print("\n2.9 — transcribe an audio file in the apps")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        var doc = TranscriptDocument()
        doc.append(text: "Hello there.", startOffset: 3, gapBefore: 3)
        let fm = TranscriptDocument.Frontmatter(title: "Interview", startedAt: at, endedAt: at.addingTimeInterval(40),
                                                version: "2.9.0", inputDevice: "ignored", engine: "stub",
                                                sourceFile: "Interview.m4a", fileSeconds: 3600.4)
        let f = TranscriptDocument.parseFrontmatter(doc.render(frontmatter: fm))?.fields ?? [:]
        expect(f["source"] ?? "nil", "file", "a file transcript says source: file")
        expect(f["source_file"] ?? "nil", "Interview.m4a", "and names the file")
        expect(f["input_device"] ?? "nil", "nil", "a file has no microphone")
        expect(f["duration_s"] ?? "nil", "3600", "duration is the audio's length, not how long transcribing took")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spiel-feed-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func tone(_ s: Double) -> [Float] { (0..<Int(s * 16000)).map { 0.5 * sin(Float($0) * 0.05) } }
        let quiet = [Float](repeating: 0, count: 16000 * 120)
        // Two minutes of silence is more than maxUnreadSeconds and releases no text:
        // pacing on released text would wait forever here.
        let silent = dir.appendingPathComponent("silent.wav")
        try? writeWAV(quiet, to: silent)
        let long = dir.appendingPathComponent("long.wav")
        try? writeWAV((0..<8).flatMap { _ in tone(3) + [Float](repeating: 0, count: 16000) }, to: long)

        let session = DictationSession(transcriber: CountingTranscriber(), vad: EnergyVAD())
        try? await session.prepare()
        await session.reset()
        let quietRun = try? await FileTranscriber.feed(silent, session: session)
        expectInt(Int(quietRun?.audioSeconds ?? -1), 120, "a long silent file finishes (back-pressure never waits on text)")

        final class Peak: @unchecked Sendable {
            private let lock = NSLock(); private var v = 0.0, last = 0.0, sum = 0.0
            func see(_ done: Double, _ total: Double) { lock.lock(); v = max(v, done); last = done; sum = total; lock.unlock() }
            var done: Double { lock.lock(); defer { lock.unlock() }; return v }
            var total: Double { lock.lock(); defer { lock.unlock() }; return sum }
        }
        let seen = Peak()
        await session.reset()
        let run = try? await FileTranscriber.feed(long, session: session) { seen.see($0, $1) }
        expectInt(run?.segments ?? -1, 8, "every stretch of speech reaches the engine")
        expectInt(Int(seen.total), 32, "progress knows the length before the file is read")
        expectInt(Int(seen.done.rounded()), 32, "progress reaches the end")

        await session.reset()
        let task = Task { try await FileTranscriber.feed(silent, session: session) }
        task.cancel()
        var cancelled = false
        do { _ = try await task.value } catch is CancellationError { cancelled = true } catch {}
        expect(cancelled ? "yes" : "no", "yes", "cancelling stops the feed")
        await session.reset()
        let after = try? await FileTranscriber.feed(long, session: session)
        expectInt(after?.segments ?? -1, 8, "the session works after a cancel (the app's dictation path shares it)")
    }

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
