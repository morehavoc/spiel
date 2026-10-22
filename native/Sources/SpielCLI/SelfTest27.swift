import Carbon.HIToolbox
import Foundation
import SpielCore

/// 2.7 — screenshots during Listen: the marker in the transcript, its file and
/// folder, the third shortcut, and Send Diagnostics keeping them out.
extension SelfTest {

    static func tests27() async {
        screenshotMarkerTests()
        screenshotFileTests()
        screenshotShortcutTests()
        screenshotDiagnosticsTests()
        appSourceRules27()
        levelMeterTests()
        levelMeterSourceRules()
    }

    // MARK: Marker rendering

    static func screenshotMarkerTests() {
        print("\n2.7 — screenshot markers in the transcript")
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        var doc = TranscriptDocument()
        doc.append(text: "First point.", startOffset: 10, gapBefore: 10, now: t)
        doc.addScreenshot(file: "screenshot-12-34.png", atOffset: 754, now: t)
        doc.append(text: "Second point.", startOffset: 760, gapBefore: 5, now: t)
        let folder = "2026-09-11 1400 Board review"
        expect(doc.body(screenshots: folder),
               "[00:10] First point.\n\n![Screenshot 12:34](2026-09-11%201400%20Board%20review/screenshot-12-34.png)\n\n[12:40] Second point.",
               "a screenshot renders as an inline Markdown image at its offset, path relative and encoded")
        expect(doc.paragraphs[1].text, "[12:34] Screenshot", "the panel's marker line reads \"[12:34] Screenshot\"")
        expect(doc.body(plain: true), "First point.\n\nSecond point.", "Copy (plain) leaves screenshots out")
        expectInt(doc.wordCount, 4, "a screenshot adds no words")
        let file = doc.render(frontmatter: .init(title: "Board review", startedAt: t, endedAt: t.addingTimeInterval(800),
                                                 version: "2.7.0", inputDevice: "Yeti", engine: "x"), screenshots: folder)
        expect(TranscriptDocument.parseFrontmatter(file)?.body.contains("![Screenshot 12:34](2026-09-11%201400%20Board%20review/") == true
               ? "ok" : file, "ok", "the saved file carries the image line after the frontmatter")

        expect(TranscriptDocument.encodePath("A (2)/screenshot-01-02.png"), "A%20%282%29/screenshot-01-02.png",
               "parentheses are encoded (a bare ')' would end the Markdown link)")
        expect(TranscriptDocument.encodePath("Café [Q3]/s.png"), "Caf%C3%A9%20%5BQ3%5D/s.png",
               "non-ASCII is UTF-8 encoded, brackets are encoded")
        expect(TranscriptDocument.imageLine(offset: 4530, folder: "", file: "screenshot-75-30.png"),
               "![Screenshot 75:30](screenshot-75-30.png)", "minutes stay unbounded, like the paragraph stamps")

        // A sentence released after the screenshot but spoken before it goes first.
        var late = TranscriptDocument()
        late.append(text: "Opening.", startOffset: 0, gapBefore: 0, now: t)
        late.addScreenshot(file: "s.png", atOffset: 20, now: t)
        late.append(text: "still the opening.", startOffset: 12, gapBefore: 0.5, now: t)
        late.append(text: "After the shot.", startOffset: 25, gapBefore: 0.5, now: t)
        expect(late.body(screenshots: "F"), "[00:00] Opening. still the opening.\n\n![Screenshot 00:20](F/s.png)\n\n[00:25] After the shot.",
               "speech that started before the screenshot lands before it, even when released after")

        var gap = TranscriptDocument()
        gap.append(text: "One.", startOffset: 0, gapBefore: 0, now: t)
        gap.addScreenshot(file: "s.png", atOffset: 30, now: t)
        gap.append(text: "Two.", startOffset: 10, gapBefore: 8, now: t)
        expect(gap.paragraphs.map { $0.image != nil ? "S" : String($0.text.prefix(3)) }.joined(separator: ","), "One,Two,S",
               "an earlier new paragraph goes before the screenshot too")

        // Taken during a pause: offset counts the pause so far; the pause marker,
        // booked when the pause ends, goes before it.
        var paused = TranscriptDocument()
        paused.append(text: "Before.", startOffset: 0, gapBefore: 0, now: t)
        paused.addScreenshot(file: "s.png", atOffset: 60, pausedFor: 90, now: t)
        paused.notePause(seconds: 120, atOffset: 60, now: t)
        paused.append(text: "After.", startOffset: 61, gapBefore: 0, now: t)
        expect(paused.body(screenshots: "F"),
               "[00:00] Before.\n\n[paused 2 min]\n\n![Screenshot 02:30](F/s.png)\n\n[03:01] After.",
               "a screenshot during a pause is stamped wall-clock true and follows the pause marker")
        var edge = TranscriptDocument()
        edge.addScreenshot(file: "s.png", atOffset: 60, now: t)
        edge.notePause(seconds: 30, atOffset: 60, now: t)
        expect(edge.paragraphs.map { $0.image != nil ? "S" : "P" }.joined(), "SP",
               "a screenshot taken just before pausing stays before the pause marker")
    }

    // MARK: Files

    static func screenshotFileTests() {
        print("\n2.7 — screenshot files beside the transcript")
        let transcript = URL(fileURLWithPath: "/tmp/T/2026-09-11 1400 Board review.md")
        expect(ScreenshotStore.folderName(forTranscript: transcript), "2026-09-11 1400 Board review",
               "the folder is named after the transcript")
        expect(ScreenshotStore.folder(forTranscript: transcript).path, "/tmp/T/2026-09-11 1400 Board review",
               "…and sits beside it")
        let f = URL(fileURLWithPath: "/x")
        var taken: Set<String> = ["/x/screenshot-12-34.png", "/x/screenshot-12-34-2.png"]
        expect(ScreenshotStore.fileName(offset: 754, in: f, exists: { taken.contains($0.path) }), "screenshot-12-34-3.png",
               "a name collision steps to -2, -3…")
        taken = []
        expect(ScreenshotStore.fileName(offset: 754.4, in: f, exists: { taken.contains($0.path) }), "screenshot-12-34.png",
               "no collision: screenshot-<mm-ss>.png")

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("spiel-selftest-shots-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let md = dir.appendingPathComponent("2026-09-11 1400 Board review.md")
            let folder = ScreenshotStore.folder(forTranscript: md)
            let a = try ScreenshotStore.save(Data([0x89, 0x50]), offset: 61, into: folder)
            let b = try ScreenshotStore.save(Data([0x89, 0x50]), offset: 61, into: folder)
            expect("\(a) \(b)", "screenshot-01-01.png screenshot-01-01-2.png", "two shots in the same second keep both files")
            let fileMode = (try fm.attributesOfItem(atPath: folder.appendingPathComponent(a).path)[.posixPermissions] as? Int) ?? -1
            let dirMode = (try fm.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int) ?? -1
            expect(String(format: "%o %o", fileMode, dirMode), "600 700", "screenshots are 0600 in a 0700 folder")
            let leftovers = try fm.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".tmp") }
            expectInt(leftovers.count, 0, "no temp files left behind")

            try "---\ntitle: x\n---\n".write(to: md, atomically: true, encoding: .utf8)
            let listed = try ListenTranscripts.list(in: dir)
            expect(listed.map(\.name).joined(separator: ","), "2026-09-11 1400 Board review.md",
                   "spiel transcripts lists the transcript, not its screenshot folder")

            let renamed = dir.appendingPathComponent("2026-09-11 1400 Budget.md")
            let moved = ScreenshotStore.follow("2026-09-11 1400 Board review", to: renamed)
            expect("\(moved.name) \(moved.error ?? "ok")", "2026-09-11 1400 Budget ok", "a title change moves the folder with the file")
            expect(fm.fileExists(atPath: dir.appendingPathComponent("2026-09-11 1400 Budget/\(a)").path) ? "moved" : "missing",
                   "moved", "…screenshots included")
            try fm.createDirectory(at: dir.appendingPathComponent("2026-09-11 1400 Taken"), withIntermediateDirectories: true)
            let blocked = ScreenshotStore.follow("2026-09-11 1400 Budget", to: dir.appendingPathComponent("2026-09-11 1400 Taken.md"))
            expect(blocked.name, "2026-09-11 1400 Budget", "an occupied name keeps the old folder, so existing links still resolve")
            expect(blocked.error == nil ? "silent" : "reported", "reported", "…and says why")
        } catch {
            expect("threw \(error)", "no throw", "screenshot file round-trip")
        }
    }

    // MARK: Shortcut

    static func screenshotShortcutTests() {
        print("\n2.7 — the Screenshot shortcut")
        typealias C = HotkeyManager.Combo
        expect(C.screenshot.description, "⌃⌥⌘S", "default is ⌃⌥⌘S")
        expect(C(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey | cmdKey)) == .screenshot ? "same" : "differs",
               "same", "a recorded ⌃⌥⌘S is labelled exactly like the default")
        let all: [(C, String)] = [(.defaultCombo, "Dictation"), (.listen, "Listen")]
        expect(HotkeyRules.validate(.screenshot, others: all) ?? "ok", "ok", "the default is not refused")
        expect(HotkeyRules.validate(.defaultCombo, others: [(.listen, "Listen"), (.screenshot, "Screenshot")]) ?? "ok",
               "ok", "…nor do the other defaults collide with it")
        expect(HotkeyRules.validate(.defaultCombo, others: [(.defaultCombo, "Dictation"), (.screenshot, "Screenshot")]) ?? "ok",
               "⌘⇧D is already the Dictation shortcut", "Screenshot set to the Dictation combo is refused, naming it")
        expect(HotkeyRules.validate(.listen, others: all) ?? "ok", "⌘⇧L is already the Listen shortcut",
               "Screenshot set to the Listen combo is refused, naming it")
        expect(HotkeyRules.validate(.screenshot, others: [(.defaultCombo, "Dictation"), (.screenshot, "Screenshot")]) ?? "ok",
               "⌃⌥⌘S is already the Screenshot shortcut", "Listen set to the Screenshot combo is refused")
        let cmdS = C(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey))
        expect((HotkeyRules.validate(cmdS, others: all) ?? "ok").contains("standard shortcut") ? "refused" : "ok", "refused",
               "⌘S stays refused for Screenshot like any shortcut")
        expect(HotkeyManager.Id.allCases.map { "\($0.rawValue)=\($0.label)" }.joined(separator: " "),
               "1=Dictation 2=Listen 3=Screenshot", "three ids; Screenshot is EventHotKeyID 3")

        let backend = StubHotkeyBackend()
        let mgr = HotkeyManager(backend: backend)
        var fired: [String] = []
        mgr.register(.dictation, .defaultCombo) { fired.append("d") }
        mgr.register(.listen, .listen) { fired.append("l") }
        mgr.register(.screenshot, .screenshot) { fired.append("s") }
        backend.route?(3); backend.route?(2); backend.route?(1)
        expect(fired.joined(separator: ","), "s,l,d", "id 3 routes to the screenshot handler only")
        expect(backend.registered[3]?.description ?? "nil", "⌃⌥⌘S", "registered with Carbon as ⌃⌥⌘S")
        mgr.unregisterAll()

        let suite = "com.morehavoc.spiel.selftest27-\(ProcessInfo.processInfo.processIdentifier)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let st = SpielSettings(defaults: d)
        expect(st.screenshotCombo.description, "⌃⌥⌘S", "Settings default is ⌃⌥⌘S")
        st.screenshotCombo = C(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey | cmdKey))
        expect(SpielSettings(defaults: d).screenshotCombo.description, "⌃⌥⌘P", "a rebound Screenshot shortcut persists")
        d.set([kVK_ANSI_L, cmdKey | shiftKey], forKey: SpielSettings.screenshotHotkeyKey)
        expect(st.screenshotCombo.description, "⌃⌥⌘S", "a stored Screenshot combo equal to Listen reads as the default")
        d.removeObject(forKey: SpielSettings.screenshotHotkeyKey)
        st.listenCombo = .screenshot
        expect(st.screenshotCombo.description, "⌃⌥⌘2", "Listen already on ⌃⌥⌘S (set before 2.7): Screenshot falls back to ⌃⌥⌘2")
        st.listenCombo = .listen
        st.screenshotCombo = .screenshot
        expect(d.object(forKey: SpielSettings.screenshotHotkeyKey) == nil ? "removed" : "kept", "removed",
               "Reset removes the stored key")
    }

    // MARK: Diagnostics

    static func screenshotDiagnosticsTests() {
        print("\n2.7 — Send Diagnostics never carries screenshots or their paths")
        let title = "MERGERTALK Acme"
        let log = """
        [2026-10-13 10:00:00.000] screenshot at 12:34 (812 KB)
        [2026-10-13 10:00:01.000] LISTEN: screenshot FAILED: Could not write /Users/x/Documents/Spiel/Transcripts/2026-10-13 1000 \(title)/screenshot-12-34.png
        [2026-10-13 10:00:02.000] error: You don’t have permission to save the file “screenshot-12-34.png” in the folder “2026-10-13 1000 \(title)”.
        [2026-10-13 10:00:03.000] wrote ![Screenshot 12:34](2026-10-13%201000%20MERGERTALK%20Acme/screenshot-12-34.png)
        """
        let tail = DiagnosticsBundle.redactedLogTail(log)
        expect(tail.contains("MERGERTALK") ? "leaked" : "clean", "clean",
               "a screenshot path, a curly-quoted folder and an image link all lose the meeting title")
        expect(tail.contains("screenshot at 12:34 (812 KB)") ? "kept" : "lost", "kept", "the screenshot event itself stays readable")
        expect(tail.contains("/Transcripts/[screenshot file]") ? "ok" : tail, "ok", "the path is replaced, not dropped")

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("spiel-selftest-diag27-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        do {
            // A real transcript folder with a screenshot in it, as Listen leaves it.
            let shots = dir.appendingPathComponent("Transcripts/2026-10-13 1000 \(title)")
            try fm.createDirectory(at: shots, withIntermediateDirectories: true)
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: shots.appendingPathComponent("screenshot-12-34.png"))
            let logURL = dir.appendingPathComponent("Spiel.log")
            try log.write(to: logURL, atomically: true, encoding: .utf8)
            let facts: [(String, String)] = [
                ("Last error", "could not write \(shots.path)/screenshot-12-34.png"),
                ("Screen Recording", "granted"),
            ]
            let out = dir.appendingPathComponent("Spiel Diagnostics")
            try DiagnosticsBundle.write(facts: facts, logURL: logURL, into: out)
            let names = try fm.contentsOfDirectory(atPath: out.path).sorted()
            expect(names.joined(separator: ","), "Spiel-log-tail.txt,report.txt", "no image file enters the bundle")
            let all = names.compactMap { try? String(contentsOf: out.appendingPathComponent($0), encoding: .utf8) }.joined()
            expect(all.contains("MERGERTALK") || all.contains(".png") && all.contains("Acme") ? "leaked" : "clean", "clean",
                   "neither the report nor the log tail names the screenshot folder")
        } catch {
            expect("threw \(error)", "no throw", "diagnostics with a screenshot folder present")
        }
    }

    // MARK: App source

    /// The capture and the app wiring cannot run here (no window server in a
    /// test, no Screen Recording grant), so their rules are pinned on the source.
    static func appSourceRules27() {
        print("\n2.7 — app-source rules (capture filter, quiet logs, Listen-only)")
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        var root: URL?
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Sources/SpielApp/ScreenCapture.swift").path) {
                root = dir; break
            }
            dir.deleteLastPathComponent()
        }
        guard let root,
              let cap = try? String(contentsOf: root.appendingPathComponent("Sources/SpielApp/ScreenCapture.swift"), encoding: .utf8),
              let main = try? String(contentsOf: root.appendingPathComponent("Sources/SpielApp/main.swift"), encoding: .utf8) else {
            print("  – SKIPPED: Sources/SpielApp not found beside this binary (nothing asserted)")
            return
        }
        expect(cap.contains("excludingApplications: content.applications.filter { $0.processID == me }") ? "ok" : "missing", "ok",
               "the content filter leaves Spiel's own windows (the Listen panel) out of the shot")
        expect(cap.contains("SCScreenshotManager.captureImage") ? "ok" : "missing", "ok", "ScreenCaptureKit, one frame")
        guard let start = main.range(of: "private func takeScreenshot()"),
              let end = main.range(of: "private func openListen()", range: start.upperBound..<main.endIndex) else {
            expect("missing", "found", "takeScreenshot exists")
            return
        }
        let body = String(main[start.lowerBound..<end.lowerBound])
        expect(body.contains("guard isListening") ? "ok" : "missing", "ok", "screenshots only while Listen is recording or paused")
        let logLines = body.split(separator: "\n").filter { $0.contains("DiagnosticLog.write(") }
        expect(logLines.contains { $0.contains("transcript") || $0.contains("folder") || $0.contains("file)") || $0.contains("path") }
               ? "names a path" : "ok", "ok", "screenshot log lines carry no file or folder name")
        expect(body.contains("screenshotFailed(") && body.contains("Notifier.post") ? "ok" : "missing", "ok",
               "a failed capture is reported, never dropped")
    }

    // MARK: 2.7.4 — level bars that move on a quiet mic

    /// Per-buffer dB for a synthetic take: ~47 buffers a second, deterministic jitter.
    /// `speech` alternates 10 buffers at the speech level with 4 dipped 15 dB (gaps
    /// between syllables); phrases are separated by `pause` buffers of room noise.
    static func meterTake(noise: Float, speech: Float, phrases: Int, pause: Int = 30,
                          leadIn: Int = 47, seed: UInt32 = 7) -> [(dB: Float, isSpeech: Bool)] {
        var state = seed
        func jitter(_ amp: Float) -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) * 2 - 1) * amp
        }
        var out: [(Float, Bool)] = []
        for _ in 0..<leadIn { out.append((noise + jitter(1.5), false)) }
        for _ in 0..<phrases {
            for _ in 0..<6 {
                for _ in 0..<10 { out.append((speech + jitter(3), true)) }
                for _ in 0..<4 { out.append((max(speech - 15, noise) + jitter(1.5), false)) }
            }
            for _ in 0..<pause { out.append((noise + jitter(1.5), false)) }
        }
        return out
    }

    static func median(_ v: [Float]) -> Float {
        guard !v.isEmpty else { return .nan }
        return v.sorted()[v.count / 2]
    }

    static func levelMeterTests() {
        print("\n2.7.4 — level bars follow the input")
        func run(_ take: [(dB: Float, isSpeech: Bool)]) -> [(old: Float, new: Float, isSpeech: Bool)] {
            var m = LevelMeter()
            return take.map { (LevelMeter.fixedLevel(dB: $0.dB), m.level(dB: $0.dB), $0.isSpeech) }
        }
        func f(_ x: Float) -> String { String(format: "%.2f", x) }

        // A quiet mic: speech around -45 dBFS over a -72 dBFS room. The fixed window
        // (-48…-18) leaves it at the bottom: the "very small or non existent" bars.
        let quiet = run(meterTake(noise: -72, speech: -45, phrases: 4))
        let quietSpeech = quiet.dropFirst(47).filter(\.isSpeech)
        let quietRoom = quiet.prefix(47).dropFirst(10) + quiet.suffix(25)
        expect(median(quietSpeech.map(\.old)) < 0.2 ? "ok" : f(median(quietSpeech.map(\.old))), "ok",
               "the fixed window keeps speech at -45 dBFS near empty (median under 0.2): the reported bug")
        expect(median(quietSpeech.map(\.new)) >= 0.5 ? "ok" : f(median(quietSpeech.map(\.new))), "ok",
               "the following window lifts the same speech to at least half height (median)")
        expect((quietRoom.map(\.new).max() ?? 1) <= 0.1 ? "ok" : f(quietRoom.map(\.new).max() ?? 1), "ok",
               "the quiet room around it stays near empty (every buffer at most 0.1)")

        // A mic that already moved the bars: never lower than before.
        let loud = run(meterTake(noise: -60, speech: -28, phrases: 4))
        expect(loud.allSatisfy { $0.new >= $0.old } ? "ok" : "lower", "ok",
               "a loud mic reads at least as high as the fixed window, on every buffer")

        // Room noise only, a noisy room: stays near empty once the window has seen it.
        let room = run(meterTake(noise: -55, speech: -55, phrases: 0, leadIn: 235))
        let roomLater = room.dropFirst(47).map(\.new).sorted()
        expect(roomLater[Int(Float(roomLater.count - 1) * 0.95)] <= 0.1 ? "ok" : f(roomLater.last ?? 1), "ok",
               "5 s of room noise at -55 dBFS: 95 % of buffers at most 0.1 after the first second")

        // A room with an occasional small sound (a click, a chair) 5 dB over it: the
        // window's minimum span keeps that from reading as speech.
        var ticks = LevelMeter()
        let tickLevels = meterTake(noise: -55, speech: -55, phrases: 0, leadIn: 235, seed: 11).enumerated()
            .map { i, b in (i % 20 == 19, ticks.level(dB: i % 20 == 19 ? -50 : b.dB)) }
            .dropFirst(47).filter(\.0).map(\.1)
        expect((tickLevels.max() ?? 1) <= 0.25 ? "ok" : f(tickLevels.max() ?? 1), "ok",
               "a sound 5 dB over the room moves the bars at most a quarter of the way")

        // A muted stretch, then noise: digital silence stays out of the window, so
        // the room after it does not fill the bars.
        var m = LevelMeter()
        let muted = (0..<94).map { _ in m.level(dB: LevelMeter.dBFS(rms: 0)) }
        expect(muted.allSatisfy { $0 == 0 } ? "ok" : "moved", "ok", "2 s of digital silence (a muted input) reads empty")
        let after = meterTake(noise: -60, speech: -60, phrases: 0, leadIn: 94, seed: 3).map { m.level(dB: $0.dB) }
        let afterSorted = after.dropFirst(23).sorted()
        expect(afterSorted[Int(Float(afterSorted.count - 1) * 0.95)] <= 0.15 ? "ok" : f(afterSorted.last ?? 1), "ok",
               "room noise after the muted stretch stays near empty (95 % at most 0.15 after 0.5 s)")

        // Talking from the first buffer, quiet mic: the bars move within half a second.
        let cold = run(meterTake(noise: -70, speech: -46, phrases: 2, leadIn: 0))
        expect((cold.prefix(23).filter(\.isSpeech).map(\.new).max() ?? 0) >= 0.5 ? "ok" : "flat", "ok",
               "speech from the very first buffer reaches half height within 0.5 s")

        // A distant speaker in a noisy room (Listen): speech stands clearly above the room.
        let far = run(meterTake(noise: -55, speech: -45, phrases: 4))
        let farSpeech = far.dropFirst(47).filter(\.isSpeech).map(\.new)
        let farRoom = far.dropFirst(47).filter { !$0.isSpeech }.map(\.new)
        expect(median(farSpeech) - median(farRoom) >= 0.3 ? "ok" : f(median(farSpeech) - median(farRoom)), "ok",
               "speech 10 dB over a -55 dBFS room: median bar at least 0.3 above the room's")

        var nanMeter = LevelMeter()
        expect([nanMeter.level(dB: .nan), nanMeter.level(dB: -.infinity), nanMeter.level(dB: 12)].map(f).joined(separator: " "),
               "0.00 0.00 1.00", "NaN and -inf read empty; above full scale is clamped to 1")
    }

    static func levelMeterSourceRules() {
        print("\n2.7.4 — app-source rules (level bars)")
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        var root: URL?
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Sources/SpielApp/main.swift").path) {
                root = dir; break
            }
            dir.deleteLastPathComponent()
        }
        guard let root,
              let main = try? String(contentsOf: root.appendingPathComponent("Sources/SpielApp/main.swift"), encoding: .utf8) else {
            print("  – SKIPPED: Sources/SpielApp not found beside this binary (nothing asserted)")
            return
        }
        guard let start = main.range(of: "private func openMicrophone("),
              let end = main.range(of: "private func beginCapture(", range: start.upperBound..<main.endIndex) else {
            expect("missing", "found", "openMicrophone exists")
            return
        }
        let body = String(main[start.lowerBound..<end.lowerBound])
        expect(body.contains("levelMeter = LevelMeter()") ? "ok" : "missing", "ok",
               "every microphone open starts the bars' window fresh")
        expect(body.contains("self.levelMeter.level(dB:") ? "ok" : "missing", "ok",
               "both panels get their bar height from LevelMeter")
        expect(body.contains("/ 30") ? "inline mapping" : "ok", "ok", "no inline fixed dB mapping left in the capture handler")
    }
}
