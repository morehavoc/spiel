import AppKit
import Foundation
import SpielCore

/// Assertions for the pure logic — the two v1 bugs that were silent, plus the
/// component most likely to cause new damage.
///
/// These live in the CLI rather than a test target because this machine has Command
/// Line Tools only, and BOTH XCTest and swift-testing ship with Xcode.app. Running
/// them as a plain executable means they work on any Mac with the toolchain, and
/// Christopher can run them himself: `spiel-cli selftest`.
/// Deterministic stand-ins so the WHOLE dictation pipeline — sink → frames → VAD →
/// segment → transcriber → assembler → glossary → report — runs in selftest with no
/// model, no mic and no TCC prompt. The bug these exist for (the sink going dead
/// after the first dictation) lived entirely in that plumbing and was invisible to
/// every test that stopped at the pure logic.
struct EnergyVAD: VoiceActivityDetector {
    func probability(of frame: [Float]) async throws -> Float {
        var sum: Float = 0
        for s in frame { sum += s * s }
        let rms = (sum / Float(max(frame.count, 1))).squareRoot()
        return rms > 0.05 ? 1 : 0
    }
    func reset() async {}
}

/// Returns a fixed word per non-empty segment, counting calls.
actor CountingTranscriber: Transcriber {
    nonisolated let kind: TranscriberKind = .parakeet
    private(set) var calls = 0
    private(set) var samplesSeen = 0
    /// Fail the next N transcribe calls, to exercise the error path.
    var failNext = 0
    func setFailNext(_ n: Int) { failNext = n }
    /// Make the next N calls take ~200 ms, so a finish() is genuinely suspended when
    /// a competing reset() arrives. Without this the race test passes vacuously.
    var slowNext = 0
    func setSlowNext(_ n: Int) { slowNext = n }
    /// How many transcribe calls were in flight at once, at most. The session must
    /// keep this at 1: the Parakeet decoder state is carried between segments and
    /// races if two calls overlap.
    private(set) var maxConcurrent = 0
    private var active = 0
    func resetConcurrency() { maxConcurrent = 0; active = 0 }
    /// `resetContext` calls, so the paragraph-gap rule can be counted rather than
    /// assumed. `reset()` also calls it once per dictation; tests zero this after.
    private(set) var contextResets = 0
    func resetContext() { contextResets += 1 }
    func zeroContextResets() { contextResets = 0 }
    func prepare() async throws {}
    func transcribe(samples: [Float]) async throws -> String {
        calls += 1
        samplesSeen += samples.count
        active += 1
        maxConcurrent = max(maxConcurrent, active)
        defer { active -= 1 }
        if failNext > 0 { failNext -= 1; throw TranscriberError.failed("stub failure") }
        if slowNext > 0 {
            slowNext -= 1
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return samples.isEmpty ? "" : "word\(calls)"
    }
}

enum SelfTest {

    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func expectInt(_ actual: Int, _ expected: Int, _ label: String) {
        expect(String(actual), String(expected), label)
    }

    static func expect(_ actual: String, _ expected: String, _ label: String) {
        checks += 1
        if actual == expected {
            print("  ✓ \(label)")
        } else {
            failures += 1
            print("  ✗ \(label)")
            print("      expected: \(expected.isEmpty ? "(empty)" : expected)")
            print("      actual  : \(actual.isEmpty ? "(empty)" : actual)")
        }
    }

    /// 16 kHz test signal: `speech` seconds of a 440 Hz tone at 0.3 amplitude,
    /// padded with `pad` seconds of silence either side.
    static func burst(speech: Double, pad: Double = 1.0) -> [Float] {
        let sr = AudioCapture.sampleRate
        let silence = [Float](repeating: 0, count: Int(pad * sr))
        var tone: [Float] = []
        tone.reserveCapacity(Int(speech * sr))
        for i in 0..<Int(speech * sr) {
            tone.append(0.3 * Float(sin(2 * Double.pi * 440 * Double(i) / sr)))
        }
        return silence + tone + silence
    }

    static func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * AudioCapture.sampleRate))
    }

    /// Feed like the microphone does: ~341-sample tap buffers, synchronously.
    static func feedLikeMic(_ session: DictationSession, _ samples: [Float]) {
        var i = 0
        while i < samples.count {
            let end = min(i + 341, samples.count)
            session.sink.submit(Array(samples[i..<end]))
            i = end
        }
    }

    /// Listen — timing on events. Offsets come from the sample counter and are fixed
    /// at segment open, so a slow engine cannot move them; a pause longer than
    /// `paragraphGap` drops the engine's carried context exactly once.
    static func listenTimingTests() async {
        print("\nListen timing — offsets from the sample counter, context reset on long gaps")

        struct Rel: Sendable { var text: String; var at: Double; var gap: Double }
        final class Box: @unchecked Sendable { var rel: [Rel] = []; var errs: [(Double, Double)] = []; let lock = NSLock() }

        func run(_ audio: [Float], slow: Int = 0, config: DictationSession.Config = .init())
            async -> (rel: [Rel], errs: [(Double, Double)], resets: Int, report: DictationSession.Report) {
            let transcriber = CountingTranscriber()
            let session = DictationSession(transcriber: transcriber, config: config, vad: EnergyVAD())
            try? await session.prepare()
            let box = Box()
            await session.setEventHandler { ev in
                box.lock.lock(); defer { box.lock.unlock() }
                switch ev {
                case .textReleased(let t, let at, let gap): box.rel.append(Rel(text: t, at: at, gap: gap))
                case .error(_, let at, let secs): box.errs.append((at, secs))
                default: break
                }
            }
            await session.reset()
            await transcriber.zeroContextResets()
            await transcriber.setSlowNext(slow)
            feedLikeMic(session, audio)
            let report = await session.finishWithReport()
            return (box.rel, box.errs, await transcriber.contextResets, report)
        }

        // Two bursts with 5 s of real silence between them. The frame grid is
        // 0.256 s, so every offset is expected to within one frame of the timeline.
        let frame = DictationSession.vadFrameSeconds
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= frame + 0.001 }
        let twoBursts = burst(speech: 1.0) + silence(3.0) + burst(speech: 1.0)  // tone at 1–2 s and 7–8 s
        let a = await run(twoBursts)
        expectInt(a.rel.count, 2, "two segments released with timing")
        if a.rel.count == 2 {
            expect(near(a.rel[0].at, 1.0) ? "ok" : "\(a.rel[0].at)", "ok", "segment 1 startOffset ≈ 1.0 s (speech onset, not pre-roll)")
            expect(near(a.rel[0].gap, 1.0) ? "ok" : "\(a.rel[0].gap)", "ok", "segment 1 gapBefore ≈ the 1 s idle lead-in")
            expect(near(a.rel[1].at, 7.0) ? "ok" : "\(a.rel[1].at)", "ok", "segment 2 startOffset ≈ 7.0 s")
            expect(near(a.rel[1].gap, 5.0) ? "ok" : "\(a.rel[1].gap)", "ok", "segment 2 gapBefore ≈ the 5 s of real silence (speech end → onset, not close → open)")
        }
        expectInt(a.resets, 1, "resetContext called exactly once — for the segment after the ≥ paragraphGap pause")
        expect(a.report.endedAt >= a.report.startedAt ? "ok" : "backwards", "ok", "report carries startedAt ≤ endedAt")
        expect(a.report.startedAt.timeIntervalSinceNow > -60 ? "ok" : "stale", "ok", "startedAt is set at reset(), not at init")

        // Same audio, slow engine: offsets are captured at segment OPEN and must not
        // drift by the engine's latency.
        let b = await run(twoBursts, slow: 2)
        expectInt(b.rel.count, 2, "slow engine: both segments still released")
        if a.rel.count == 2 && b.rel.count == 2 {
            expect(b.rel.map { String(format: "%.3f/%.3f", $0.at, $0.gap) }.joined(separator: " "),
                   a.rel.map { String(format: "%.3f/%.3f", $0.at, $0.gap) }.joined(separator: " "),
                   "offsets and gaps are identical with a slow engine (sample counter, not wall clock)")
        }

        // Short gap: two bursts 0.4 s apart. No context reset, gap reads short.
        let close = burst(speech: 0.8, pad: 0.2) + burst(speech: 0.8, pad: 0.2)  // 0.4 s between tones
        var cfg = DictationSession.Config()
        cfg.silenceDuration = 0.25  // one frame, so the 0.4 s pause closes the segment
        let c = await run(close, config: cfg)
        expectInt(c.rel.count, 2, "short gap: two segments")
        if c.rel.count == 2 {
            expect(c.rel[1].gap < 2.0 ? "ok" : "\(c.rel[1].gap)", "ok", "short gap reads under paragraphGap")
        }
        expectInt(c.resets, 0, "no context reset when every gap is under paragraphGap")

        // A failed segment reports where it was and how long, so Listen can mark
        // the hole instead of silently closing it.
        do {
            let transcriber = CountingTranscriber()
            let session = DictationSession(transcriber: transcriber, vad: EnergyVAD())
            try? await session.prepare()
            let box = Box()
            await session.setEventHandler { ev in
                box.lock.lock(); defer { box.lock.unlock() }
                if case .error(_, let at, let secs) = ev { box.errs.append((at, secs)) }
            }
            await session.reset()
            await transcriber.setFailNext(1)
            feedLikeMic(session, burst(speech: 1.0))
            _ = await session.finishWithReport()
            expectInt(box.errs.count, 1, "engine failure emits one .error with position")
            if let e = box.errs.first {
                expect(near(e.0, 1.0) ? "ok" : "\(e.0)", "ok", ".error startOffset is the failed segment's onset")
                expect(e.1 >= 1.0 && e.1 <= 2.5 ? "ok" : "\(e.1)", "ok", ".error seconds is the failed segment's audio length (speech + pre-roll + trailing silence)")
            }
        }

        // Pause and capture-restart counters ride on the report.
        do {
            let session = DictationSession(transcriber: CountingTranscriber(), vad: EnergyVAD())
            try? await session.prepare()
            await session.reset()
            await session.notePause(seconds: 12.5)
            await session.notePause(seconds: -3)  // a negative span is a bug upstream; never subtract
            await session.noteCaptureRestart()
            let r = await session.finishWithReport()
            expect(String(format: "%.1f", r.pausedSeconds), "12.5", "notePause accumulates onto the report and ignores a negative span")
            expectInt(r.captureRestarts, 1, "noteCaptureRestart counts onto the report")
            await session.reset()
            let r2 = await session.finishWithReport()
            expect(String(format: "%.1f", r2.pausedSeconds), "0.0", "reset() clears pausedSeconds")
            expectInt(r2.captureRestarts, 0, "reset() clears captureRestarts")
        }

        // The "audio is dropped" claim, asserted: 40 segments through a session
        // that is never reset, text in capture order, and the audio buffers empty
        // between segments. Memory for an hour is bounded by text, not audio.
        do {
            var many: [Float] = []
            for _ in 0..<40 { many += burst(speech: 0.6, pad: 0.5) }
            let d = await run(many)
            expectInt(d.rel.count, 40, "40 segments on one never-reset session all release")
            expect(d.rel.map(\.text).joined(separator: " "), (1...40).map { "word\($0)" }.joined(separator: " "),
                   "40 segments release in capture order")
            expect(d.rel.map(\.at) == d.rel.map(\.at).sorted() ? "ok" : "unsorted", "ok",
                   "startOffsets are monotonic across 40 segments")
            expect(String(Int(d.report.audioSeconds.rounded())), "64", "40 × 1.6 s of audio all reached the session")
            expect(d.report.text.split(separator: " ").count == 40 ? "ok" : "\(d.report.text.split(separator: " ").count)", "ok",
                   "final report text holds all 40 words")
        }
    }

    /// A backend that records what the manager asked for and can be told to fail
    /// one id. No real Carbon registration happens here — that would take ⌘⇧D away
    /// from the running app.
    final class StubHotkeyBackend: HotkeyManager.Backend {
        var registered: [UInt32: HotkeyManager.Combo] = [:]
        var failIds: Set<UInt32> = []
        var handlerInstalls = 0
        var route: ((UInt32) -> Void)?
        final class Tok { let id: UInt32; init(_ i: UInt32) { id = i } }
        func installHandler(_ route: @escaping (UInt32) -> Void) -> Result<Void, HotkeyManager.RegisterError> {
            handlerInstalls += 1; self.route = route; return .success(())
        }
        func register(_ combo: HotkeyManager.Combo, id: UInt32) -> Result<AnyObject, HotkeyManager.RegisterError> {
            if failIds.contains(id) { return .failure(.taken) }
            registered[id] = combo
            return .success(Tok(id))
        }
        func unregister(_ token: AnyObject) { if let t = token as? Tok { registered[t.id] = nil } }
        func removeHandler() { route = nil }
    }

    static func hotkeyRoutingTests() {
        print("\nHotkeyManager — two ids, routed on EventHotKeyID, failures isolated")
        let backend = StubHotkeyBackend()
        let mgr = HotkeyManager(backend: backend)
        var fired: [String] = []
        var statuses: [String] = []
        mgr.setStatusHandler { id, st in statuses.append("\(id):\(st.isHealthy ? "ok" : "no")") }
        expect(statuses.sorted().joined(separator: ","), "dictation:no,listen:no", "status handler reports both ids on install")

        mgr.register(.dictation, .defaultCombo) { fired.append("dictation") }
        mgr.register(.listen, .listen) { fired.append("listen") }
        expect(mgr.status(.dictation).isHealthy && mgr.status(.listen).isHealthy ? "ok" : "no", "ok", "both hotkeys register")
        expectInt(backend.handlerInstalls, 1, "the Carbon event handler is installed once, not per hotkey")
        expect(backend.registered[1]?.description ?? "nil", "⌘⇧D", "id 1 is dictation ⌘⇧D")
        expect(backend.registered[2]?.description ?? "nil", "⌘⇧L", "id 2 is Listen ⌘⇧L")

        // Route through the SAME closure the Carbon callback would call.
        backend.route?(2)
        expect(fired.joined(separator: ","), "listen", "a synthetic event with id 2 fires only the Listen handler")
        backend.route?(1)
        expect(fired.joined(separator: ","), "listen,dictation", "id 1 fires only the dictation handler")
        backend.route?(7)
        expect(fired.joined(separator: ","), "listen,dictation", "an unknown id fires nothing")

        // Failure of id 2 leaves id 1 registered and working.
        fired.removeAll()
        backend.failIds = [2]
        let st = mgr.register(.listen, .listen) { fired.append("listen") }
        expect(st.isHealthy ? "healthy" : "failed", "failed", "a taken Listen combo reports failure")
        if case .failed(let d, let reason) = st {
            expect(d, "⌘⇧L", "…naming the combo")
            expect(reason.contains("another app already owns") ? "ok" : reason, "ok", "…and the reason")
        }
        expect(mgr.status(.dictation).isHealthy ? "ok" : "lost", "ok", "dictation stays registered when Listen fails")
        expect(backend.registered[1] != nil ? "ok" : "gone", "ok", "…and its Carbon registration was not touched")
        backend.route?(1)
        expect(fired.joined(separator: ","), "dictation", "dictation still fires after the Listen failure")
        backend.route?(2)
        expect(fired.joined(separator: ","), "dictation", "a failed id does not fire a stale handler")

        // Re-registering one id (F5 fallback) replaces only that id.
        backend.failIds = []
        mgr.register(.listen, .listen) { fired.append("listen") }
        mgr.register(.dictation, .f5) { fired.append("f5") }
        expect(backend.registered[1]?.description ?? "nil", "F5", "the F5 fallback replaces the dictation combo")
        expect(backend.registered[2]?.description ?? "nil", "⌘⇧L", "…and leaves Listen on ⌘⇧L")
        fired.removeAll()
        backend.route?(1); backend.route?(2)
        expect(fired.joined(separator: ","), "f5,listen", "after the swap both ids route to their current handlers")
        expectInt(backend.registered.count, 2, "no leaked registrations after re-registering")

        mgr.unregisterAll()
        expectInt(backend.registered.count, 0, "unregisterAll releases every registration")
        expect(backend.route == nil ? "removed" : "kept", "removed", "unregisterAll removes the event handler")
        expect(HotkeyManager.Id.listen.rawValue == 2 && HotkeyManager.Id.dictation.rawValue == 1 ? "ok" : "no", "ok",
               "ids are the EventHotKeyID values the Carbon callback reads back (1 dictation, 2 listen)")
    }

    /// Source-anchored rules the CLI cannot exercise at runtime (the app is AppKit).
    /// Finds the package root by walking up from this executable; if the source is
    /// not beside the binary (an installed CLI), the section is SKIPPED and says so
    /// rather than passing vacuously.
    static func listenSourceRules() {
        print("\nListen — app-source rules (design §5)")
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        var main: URL?
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Sources/SpielApp/main.swift")
            if FileManager.default.fileExists(atPath: candidate.path) { main = candidate; break }
            dir.deleteLastPathComponent()
        }
        guard let main, let src = try? String(contentsOf: main, encoding: .utf8) else {
            print("  – SKIPPED: Sources/SpielApp/main.swift not found beside this binary (nothing asserted)")
            return
        }
        // Body of one `private func name(` up to the next top-level member. Comments
        // are stripped first so an assertion cannot match prose that discusses the
        // rule (#131/#152/#166 shape).
        func body(of name: String) -> String? {
            let stripped = src.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    if let r = line.range(of: "//") { return String(line[..<r.lowerBound]) }
                    return String(line)
                }.joined(separator: "\n")
            guard let start = stripped.range(of: "private func \(name)(") else { return nil }
            let rest = stripped[start.upperBound...]
            let end = rest.range(of: "\n    private func ") ?? rest.range(of: "\n    @objc ") ?? rest.range(of: "\n    // MARK") ?? rest.endIndex..<rest.endIndex
            return String(rest[..<end.lowerBound])
        }
        guard let listen = body(of: "startListening"), let dictate = body(of: "start") else {
            expect("missing", "found", "startListening() and start() exist in main.swift")
            return
        }
        // The counter-check first: the dictation path DOES read Secure Input, so a
        // rename of the API cannot make the next assertion pass for nothing.
        expect(dictate.contains("isSecureInputEnabled()") ? "reads" : "missing", "reads",
               "start() (dictation) still latches Secure Input")
        expect(listen.contains("isSecureInputEnabled") ? "reads" : "clean", "clean",
               "startListening() never reads Secure Input — skipped, not inherited (§5.6)")
        expect(listen.contains("captureFrontmostApp") ? "captures" : "clean", "clean",
               "startListening() does not capture a target app (Listen never pastes)")
        expect(listen.contains("WindowTitle.frontmost()") ? "ok" : "missing", "ok",
               "startListening() pre-fills the title from the frontmost window")
        guard let toggle = body(of: "toggle") else { expect("missing", "found", "toggle() exists"); return }
        expect(toggle.contains("case .recording(.listen), .paused:") && toggle.contains("stop it to dictate") ? "ok" : "missing", "ok",
               "⌘⇧D during Listen is refused with a reason, not multiplexed (§5.1)")
        expect(src.contains("case .paused:\n            symbol = \"pause.circle\"") || src.contains("symbol = \"pause.circle\"") ? "ok" : "missing", "ok",
               "paused Listen has its own status symbol")
        expect(src.contains("symbol = \"waveform\"") ? "ok" : "missing", "ok",
               "Listen has a status symbol distinct from dictation's mic.fill")
        guard let route = body(of: "captureRouteChanged") else { expect("missing", "found", "captureRouteChanged exists"); return }
        expect(route.contains("noteCaptureRestart(device:") && route.contains("stopListening()") ? "ok" : "missing", "ok",
               "a route change writes a marker on success and stops Listen (with a notification) on failure")
    }

    static func transcriptDocumentTests() {
        print("\nTranscriptDocument — paragraphs, markers, offsets, rendering")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var doc = TranscriptDocument()
        doc.append(text: "Okay so the first thing", startOffset: 0.5, gapBefore: 0.5, now: t0)
        doc.append(text: "is the Gresham RFP.", startOffset: 3.0, gapBefore: 0.8, now: t0)
        expectInt(doc.paragraphs.count, 1, "a short gap extends the current paragraph")
        expect(doc.paragraphs[0].text, "Okay so the first thing is the Gresham RFP.", "segments join with a space")
        doc.append(text: "Second topic.", startOffset: 41.0, gapBefore: 2.0, now: t0)
        expectInt(doc.paragraphs.count, 2, "a gap of exactly paragraphGap starts a new paragraph")
        expect(TranscriptDocument.formatOffset(doc.paragraphs[1].offset), "00:41", "paragraph offset is its first segment's onset")
        doc.append(text: "Still second.", startOffset: 43.0, gapBefore: 1.99, now: t0)
        expectInt(doc.paragraphs.count, 2, "1.99 s stays in the paragraph")

        // Monologue cap: one speaker, no 2 s gap for two minutes.
        var mono = TranscriptDocument()
        var at = 0.0
        var n = 0
        while at < 120 { mono.append(text: "w\(n)", startOffset: at, gapBefore: 0.5, now: t0); at += 10; n += 1 }
        expectInt(mono.paragraphs.count, 2, "a 120 s monologue with no gaps is split by the 90 s cap")
        expect(mono.paragraphs.count > 1 ? TranscriptDocument.formatOffset(mono.paragraphs[1].offset) : "unsplit", "01:30",
               "the cap splits at the first segment past 90 s")

        // Markers are their own paragraphs and never get speech glued on.
        var m = TranscriptDocument()
        m.append(text: "Before.", startOffset: 10, gapBefore: 10, now: t0)
        m.noteCaptureRestart(device: "AirPods Pro", atOffset: 31 * 60 + 7, now: t0)
        m.append(text: "After.", startOffset: 31 * 60 + 9, gapBefore: 0.3, now: t0)
        expectInt(m.paragraphs.count, 3, "a marker sits between two paragraphs even with a short gap after it")
        expect(m.paragraphs[1].text, "[input changed to AirPods Pro at 31:07]", "capture-restart marker text")
        expect(m.paragraphs[1].isMarker ? "marker" : "text", "marker", "the marker paragraph is flagged")
        expect(m.paragraphs.last?.text ?? "nil", "After.", "speech after a marker starts fresh, not appended to the marker")
        m.noteMissed(seconds: 8.2, atOffset: 40 * 60, now: t0)
        expect(m.paragraphs.last?.text ?? "nil", "[missed ~8 s at 40:00]", "missed-segment marker text")
        expectInt(m.wordCount, 2, "wordCount ignores marker lines")

        // Pause correction: a 4-minute pause at 20:00 shifts every later offset.
        var pz = TranscriptDocument()
        pz.append(text: "Before the pause.", startOffset: 19 * 60, gapBefore: 5, now: t0)
        pz.notePause(seconds: 240, atOffset: 20 * 60, now: t0)
        pz.append(text: "After the pause.", startOffset: 20 * 60 + 5, gapBefore: 5, now: t0)
        expectInt(pz.paragraphs.count, 3, "pause marker + two paragraphs")
        guard pz.paragraphs.count == 3 else { return }
        expect(pz.paragraphs[1].text, "[paused 4 min]", "pause marker text")
        expect(TranscriptDocument.formatOffset(pz.paragraphs[1].offset), "20:00", "pause marker sits at the pause")
        expect(TranscriptDocument.formatOffset(pz.paragraphs[2].offset), "24:05", "offsets after a pause include the paused time (wall-clock-true)")
        expect(TranscriptDocument.formatOffset(pz.paragraphs[0].offset), "19:00", "offsets before the pause are untouched")
        pz.notePause(seconds: 0, atOffset: 25 * 60, now: t0)
        expectInt(pz.paragraphs.count, 3, "a zero-length pause writes no marker")

        // Render + round trip.
        let started = t0
        let ended = t0.addingTimeInterval(3154)
        let fm = TranscriptDocument.Frontmatter(title: "Projects Weekly: Q3", startedAt: started, endedAt: ended,
                                                version: "2.1.0", inputDevice: "Yeti Stereo Microphone", engine: "parakeet-tdt-0.6b-v3")
        let rendered = pz.render(frontmatter: fm)
        expect(rendered.hasPrefix("---\napp: Spiel\n") ? "ok" : String(rendered.prefix(20)), "ok", "render starts with YAML frontmatter")
        guard let parsed = TranscriptDocument.parseFrontmatter(rendered) else {
            expect("nil", "parsed", "rendered frontmatter parses"); return
        }
        expect(parsed.fields["title"] ?? "nil", "Projects Weekly: Q3", "a title with a colon round-trips (quoted in YAML)")
        expect(parsed.fields["duration_s"] ?? "nil", "3154", "duration_s is ended − started")
        expect(parsed.fields["words"] ?? "nil", "6", "words is the speech word count")
        expect(parsed.fields["kind"] ?? "nil", "transcript", "kind: transcript")
        expect(parsed.fields["source"] ?? "nil", "microphone", "source: microphone")
        expect(parsed.fields["engine"] ?? "nil", "parakeet-tdt-0.6b-v3", "engine round-trips")
        let iso = parsed.fields["started"] ?? ""
        expect(iso.count == 25 && (iso.hasSuffix("Z") == false) && (iso.contains("+") || iso.dropFirst(19).contains("-")) ? "ok" : iso, "ok",
               "started is ISO 8601 with a numeric UTC offset, never naive local time")
        let f = ISO8601DateFormatter()
        expect(f.date(from: iso).map { String(format: "%.0f", $0.timeIntervalSince1970) } ?? "unparsed",
               String(format: "%.0f", started.timeIntervalSince1970), "started parses back to the same instant")
        expect(parsed.body.hasPrefix("[19:00] Before the pause.") ? "ok" : String(parsed.body.prefix(30)), "ok", "body follows the frontmatter with [MM:SS] paragraphs")
        expect(parsed.body.contains("\n\n[paused 4 min]\n\n") ? "ok" : "missing", "ok", "paragraphs are separated by a blank line")
        expect(pz.body(plain: true), "Before the pause.\n\nAfter the pause.", "plain body drops offsets and markers (for Copy)")
        expect(TranscriptDocument.parseFrontmatter("no frontmatter here") == nil ? "nil" : "parsed", "nil", "text without frontmatter does not parse as one")
        expect(TranscriptDocument.formatOffset(75 * 60 + 12), "75:12", "offsets past an hour stay MM:SS")
        expect(TranscriptDocument.formatDuration(45), "45 s", "duration under a minute")
        expect(TranscriptDocument.formatDuration(72 * 60), "1 h 12 min", "duration over an hour")
        expect(pz.lastParagraphAge(now: t0.addingTimeInterval(31)).map { String(Int($0)) } ?? "nil", "31", "lastParagraphAge is measured from the newest append")
        expect(TranscriptDocument().lastParagraphAge() == nil ? "nil" : "value", "nil", "an empty document has no last-paragraph age")
        var e = TranscriptDocument()
        e.append(text: "   ", startOffset: 1, gapBefore: 1, now: t0)
        expectInt(e.paragraphs.count, 0, "whitespace-only text is not appended")
    }

    static func transcriptStoreTests() {
        print("\nTranscriptStore — naming, collisions, atomic writes")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let stamp: String = {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HHmm"; return f.string(from: t0)
        }()
        expect(TranscriptStore.fileName(title: "Projects Weekly", startedAt: t0), "\(stamp) Projects Weekly.md", "file name is local start stamp + title")
        expect(TranscriptStore.fileName(title: "", startedAt: t0), "\(stamp) Untitled.md", "empty title → Untitled")
        expect(TranscriptStore.fileName(title: "   ", startedAt: t0), "\(stamp) Untitled.md", "whitespace title → Untitled")
        expect(TranscriptStore.sanitize("Sync: a/b \\ c\nd"), "Sync- a-b - c-d", "/, :, \\ and newlines become -")
        expect(TranscriptStore.sanitize("...hidden"), "hidden", "a leading dot is stripped so the file is not hidden")
        expectInt(TranscriptStore.sanitize(String(repeating: "x", count: 200)).count, 80, "titles are clipped to 80 characters")

        let folder = URL(fileURLWithPath: "/tmp/spiel-store-test")
        let taken = Set([folder.appendingPathComponent("\(stamp) Weekly.md").path,
                         folder.appendingPathComponent("\(stamp) Weekly (2).md").path])
        let u1 = TranscriptStore.url(for: "Weekly", startedAt: t0, in: folder, exists: { taken.contains($0.path) })
        expect(u1.lastPathComponent, "\(stamp) Weekly (3).md", "a taken name steps to the next free suffix")
        let own = folder.appendingPathComponent("\(stamp) Weekly.md")
        let u2 = TranscriptStore.url(for: "Weekly", startedAt: t0, in: folder, current: own, exists: { taken.contains($0.path) })
        expect(u2.lastPathComponent, "\(stamp) Weekly.md", "this session's OWN file keeps its name on autosave (no suffix creep)")

        // Real writes in a scratch folder: atomic replace, 0600, no temp left behind,
        // and a title change moves the file.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("spiel-selftest-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let a = scratch.appendingPathComponent("a.md")
        do {
            try TranscriptStore.save("one", to: a)
            expect((try? String(contentsOf: a, encoding: .utf8)) ?? "nil", "one", "save writes the text (creating the folder)")
            let perms = (try? FileManager.default.attributesOfItem(atPath: a.path)[.posixPermissions] as? Int) ?? -1
            expect(String(perms, radix: 8), "600", "transcript file is mode 0600")
            try TranscriptStore.save("two", to: a)
            expect((try? String(contentsOf: a, encoding: .utf8)) ?? "nil", "two", "a second save replaces the content")
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path))?.filter { $0.hasSuffix(".tmp") } ?? []
            expectInt(leftovers.count, 0, "no temp file is left behind after a save")
            let b = scratch.appendingPathComponent("b.md")
            try TranscriptStore.save("three", to: b, replacing: a)
            expect(FileManager.default.fileExists(atPath: a.path) ? "still there" : "gone", "gone", "a title change removes the old file after the new one is in place")
            expect((try? String(contentsOf: b, encoding: .utf8)) ?? "nil", "three", "…and the new file holds the text")
            try TranscriptStore.save("four", to: b, replacing: b)
            expect(FileManager.default.fileExists(atPath: b.path) ? "there" : "gone", "there", "replacing a file with itself does not delete it")
        } catch {
            expect("\(error)", "", "store writes succeed")
        }
        // A folder that cannot be created is a thrown error, not a silent no-op.
        let bad = URL(fileURLWithPath: "/dev/null/nope/x.md")
        do { try TranscriptStore.save("x", to: bad); expect("saved", "threw", "an unwritable folder throws") }
        catch { expect("threw", "threw", "an unwritable folder throws") }
    }

    static func pipelineTests() async {
        print("\nDictation pipeline — sink → VAD → segment → engine → report (no model, no mic)")

        let transcriber = CountingTranscriber()
        let session = DictationSession(transcriber: transcriber, vad: EnergyVAD())
        do { try await session.prepare() } catch {
            expect("\(error)", "", "session prepares with injected VAD")
            return
        }
        expect(await session.isArmed ? "armed" : "disarmed", "armed", "session is armed after prepare()")

        // Round 1 — the path that always worked.
        await session.reset()
        feedLikeMic(session, burst(speech: 1.0))
        let r1 = await session.finishWithReport()
        expect(r1.text, "word1", "round 1: one burst becomes one transcribed segment")
        expectInt(r1.segments, 1, "round 1: exactly one segment closed")
        expectInt(r1.droppedBuffers, 0, "round 1: no buffers dropped")
        expect(String(format: "%.2f", r1.audioSeconds), "3.00", "round 1: report counts all audio that arrived")
        expect(r1.peak > 0.29 && r1.peak <= 0.3 ? "ok" : "\(r1.peak)", "ok", "round 1: report carries the peak level")
        expect(await session.isArmed ? "armed" : "disarmed", "disarmed", "after finish() the session is disarmed")

        // Between dictations: audio submitted with no armed stream is COUNTED, not lost
        // silently. This is what a regression of the one-shot-sink bug looks like.
        session.sink.submit([Float](repeating: 0.1, count: 341))
        expectInt(session.sink.droppedBuffers, 1, "a submit while disarmed is counted as dropped")

        // Round 2 — THE BUG. Before the fix, the AsyncStream had been finished in
        // round 1, every submit here was discarded, and the report would read
        // 0.00s of audio / no text while the app still said "Listening…".
        await session.reset()
        expect(await session.isArmed ? "armed" : "disarmed", "armed", "reset() re-arms the audio path")
        expectInt(session.sink.droppedBuffers, 0, "reset() clears the dropped count")
        feedLikeMic(session, burst(speech: 1.0))
        let r2 = await session.finishWithReport()
        expect(r2.text, "word2", "round 2 on the SAME session still transcribes (sink re-armed)")
        expectInt(r2.segments, 1, "round 2: one segment")
        expect(String(format: "%.2f", r2.audioSeconds), "3.00", "round 2: all audio reached the session")
        expectInt(r2.droppedBuffers, 0, "round 2: nothing dropped")

        // Round 3 — two bursts, ordered. The first is SLOW, so under the old
        // one-Task-per-segment scheme the second would have entered the engine while
        // the first was still inside it (both bursts are pre-fed, so the VAD closes
        // them milliseconds apart). Segments must be transcribed one at a time, in
        // capture order: the engine carries decoder state between them.
        await session.reset()
        await transcriber.resetConcurrency()
        await transcriber.setSlowNext(1)
        feedLikeMic(session, burst(speech: 0.8) + burst(speech: 0.8))
        let r3 = await session.finishWithReport()
        expect(r3.text, "word3 word4", "two bursts become two segments in speech order")
        expectInt(r3.segments, 2, "round 3: two segments")
        expectInt(await transcriber.maxConcurrent, 1,
                  "segments are transcribed one at a time (carried decoder state must not race)")

        // Diagnoses — the three kinds of "nothing", told apart.
        await session.reset()
        let rEmpty = await session.finishWithReport()
        expect(rEmpty.text, "", "no audio: empty text")
        expect(rEmpty.diagnosis.contains("no audio reached the session") ? "ok" : rEmpty.diagnosis, "ok",
               "no audio: diagnosis says the mic delivered nothing")

        await session.reset()
        feedLikeMic(session, [Float](repeating: 0.0005, count: 16_000 * 2))
        let rSilent = await session.finishWithReport()
        expect(rSilent.text, "", "near-silence: empty text")
        expect(rSilent.diagnosis.contains("near-silence") ? "ok" : rSilent.diagnosis, "ok",
               "near-silence: diagnosis names the mic/permission/device, not the engine")

        await session.reset()
        feedLikeMic(session, [Float](repeating: 0.02, count: 16_000 * 2))  // audible, below VAD
        let rNoSpeech = await session.finishWithReport()
        expect(rNoSpeech.text, "", "audio without speech: empty text")
        expect(rNoSpeech.diagnosis.contains("no speech detected") ? "ok" : rNoSpeech.diagnosis, "ok",
               "audio without speech: diagnosis says no speech was detected")

        expect(r1.diagnosis.contains("1 words") || r1.diagnosis.contains("1 word") ? "ok" : r1.diagnosis, "ok",
               "success: diagnosis reports word count")
        expect(r1.diagnosis.hasPrefix("PARTIAL") ? "partial" : "clean", "clean",
               "success with nothing wrong is not labelled PARTIAL")

        // Engine failure — the diagnosis must name the failure, not the reassuring
        // "no speech" or a bare word count.
        await session.reset()
        await transcriber.setFailNext(1)
        feedLikeMic(session, burst(speech: 1.0))
        let rFail = await session.finishWithReport()
        expect(rFail.text, "", "engine failure: empty text")
        expectInt(rFail.errors.count, 1, "engine failure: error recorded in the report")
        expect(rFail.diagnosis.contains("failed") ? "ok" : rFail.diagnosis, "ok",
               "engine failure: diagnosis says a segment failed")

        // Partial — one of two segments fails. Text is non-empty AND the diagnosis
        // must still lead with the failure.
        await session.reset()
        await transcriber.setFailNext(1)
        feedLikeMic(session, burst(speech: 0.8) + burst(speech: 0.8))
        let rPartial = await session.finishWithReport()
        expect(rPartial.text.isEmpty ? "empty" : "text", "text", "partial: the surviving segment's text is delivered")
        expect(rPartial.diagnosis.hasPrefix("PARTIAL") ? "ok" : rPartial.diagnosis, "ok",
               "partial: diagnosis leads with PARTIAL, not the word count")

        // A report with dropped buffers is never labelled clean, even with text.
        var rDrop = DictationSession.Report()
        rDrop.text = "hello there"; rDrop.audioSeconds = 2; rDrop.segments = 1; rDrop.droppedBuffers = 7
        expect(rDrop.diagnosis.contains("7 audio buffers dropped") && rDrop.diagnosis.hasPrefix("PARTIAL") ? "ok" : rDrop.diagnosis, "ok",
               "dropped buffers with text: diagnosis leads with the drop")

        // reset() WITHOUT a finish, while a segment is still inside the engine: the
        // abandoned segment must not `accept` its text into the next dictation. If
        // it did, the old text would land at index 0 and the new dictation's real
        // first segment would be held back to the end.
        await session.reset()
        await transcriber.setSlowNext(1)
        feedLikeMic(session, burst(speech: 1.0))
        try? await Task.sleep(nanoseconds: 700_000_000)  // segment closed, engine sleeping
        await session.reset()  // abandon it
        feedLikeMic(session, burst(speech: 1.0))
        let rAbandon = await session.finishWithReport()
        expectInt(rAbandon.segments, 1, "abandoned dictation: the new one counts only its own segment")
        expect(rAbandon.text.split(separator: " ").count == 1 ? "one" : rAbandon.text, "one",
               "abandoned dictation: its text does not leak into the next one")

        // Fast second press: reset() while finish() is still suspended must wait for
        // it, not interleave. Run them concurrently and require both to be coherent.
        await session.reset()
        await transcriber.setSlowNext(1)
        feedLikeMic(session, burst(speech: 1.0))
        async let finishing = session.finishWithReport()
        try? await Task.sleep(nanoseconds: 30_000_000)  // let finish() reach its await
        await session.reset()  // arrives while finish is suspended in the engine
        let rRace = await finishing
        expect(rRace.text.isEmpty ? "empty" : "text", "text", "reset() during finish(): finish still returns its own text")
        expect(await session.isArmed ? "armed" : "disarmed", "armed",
               "reset() during finish(): session ends up armed for the next dictation")
        feedLikeMic(session, burst(speech: 1.0))
        let rAfter = await session.finishWithReport()
        expect(rAfter.text.isEmpty ? "empty" : "text", "text", "dictation after the race still works")
        expectInt(rAfter.droppedBuffers, 0, "dictation after the race: nothing dropped")
    }

    static func run() async -> Int32 {
        print("spiel selftest\n")

        print("TranscriptAssembler — speech-order reassembly")

        // The v1 bug: results were appended in COMPLETION order, so a slow first
        // segment and a fast second one swapped two sentences.
        do {
            let a = TranscriptAssembler()
            let early = await a.accept(.init(index: 1, text: "second sentence"))
            expect(early, "", "index 1 is held until index 0 arrives")
            let released = await a.accept(.init(index: 0, text: "first sentence"))
            expect(released, "first sentence second sentence", "out-of-order arrival reassembles in speech order")
            expect(await a.text(), "first sentence second sentence", "full transcript is in speech order")
        }

        do {
            let a = TranscriptAssembler()
            expect(await a.accept(.init(index: 0, text: "one")), "one", "contiguous index 0 releases immediately")
            expect(await a.accept(.init(index: 1, text: "two")), "two", "contiguous index 1 releases immediately")
        }

        // A failed segment must not swallow everything spoken after it.
        do {
            let a = TranscriptAssembler()
            _ = await a.accept(.init(index: 1, text: "kept"))
            expect(await a.accept(.init(index: 0, text: "")), "kept",
                   "an empty placeholder does not stall the gate")
        }

        // Punctuation-only segments are noise, not text ("Okay. . Let's see").
        do {
            let a = TranscriptAssembler()
            _ = await a.accept(.init(index: 0, text: "Okay."))
            _ = await a.accept(.init(index: 1, text: "."))
            _ = await a.accept(.init(index: 2, text: "Let's see."))
            expect(await a.text(), "Okay. Let's see.", "a bare '.' segment is dropped, not joined")
            _ = await a.accept(.init(index: 4, text: "…"))
            _ = await a.flush()
            expect(await a.text(), "Okay. Let's see.", "flush also drops punctuation-only segments")
            let b = TranscriptAssembler()
            expect(await b.accept(.init(index: 0, text: "3")), "3", "a digit is real text, not noise")
            // Doubled punctuation INSIDE a segment (engine fired on a pause).
            let c = TranscriptAssembler()
            _ = await c.accept(.init(index: 0, text: "talking to it. . Uh sure"))
            expect(await c.text(), "talking to it. Uh sure", "'it. . Uh' inside one segment collapses to one period")
            expect(TranscriptAssembler.tidy("wait . what"), "wait . what", "a lone '.' after a word without punctuation is left alone")
            expect(TranscriptAssembler.tidy("really? ! yes"), "really? yes", "'? !' collapses to the first mark")
        }

        // A permanently missing segment must not silently eat the rest.
        do {
            let a = TranscriptAssembler()
            _ = await a.accept(.init(index: 3, text: "orphan"))
            expect(await a.text(), "", "orphan is held back before flush")
            _ = await a.flush()
            expect(await a.text(), "orphan", "flush releases orphans")
        }

        print("\nGlossary — custom vocabulary without regex-over-prose")
        let g = Glossary()
        expect(g.apply(to: "publish the arc gis layer as geo json"),
               "publish the ArcGIS layer as GeoJSON", "multi-word terms are joined and canonicalised")
        expect(g.apply(to: "send it to dymaptic."), "send it to dymaptic.", "trailing period survives")
        expect(g.apply(to: "is it geo json?"), "is it GeoJSON?", "trailing question mark survives")
        expect(g.apply(to: "ESRI and esri and Esri"), "Esri and Esri and Esri", "case-insensitive single tokens")
        expect(g.apply(to: "open survey 123 now"), "open Survey123 now", "longest span wins")
        // Real engine misses observed 2026-09-02 on jaws-mini.
        expect(g.apply(to: "as G OJSON,"), "as GeoJSON,", "repairs Parakeet's 'G OJSON'")
        expect(g.apply(to: "the Dimaptic team"), "the dymaptic team", "repairs Parakeet's 'Dimaptic'")
        expect(g.apply(to: ""), "", "empty string is safe")
        expect(g.apply(to: "   "), "   ", "whitespace is safe")

        expect(g.apply(to: "I said ArcJS not arc js"), "I said ArcGIS not ArcGIS", "repairs Parakeet's 'ArcJS' (2026-09-02)")

        print("\nVocabulary file — user-editable, merged over built-ins")
        let parsed = Glossary.parse("""
        # comment line

        ArcGIS: arc gis, arcjs
        Roscoe
        Kumquat : kum kwat,  cumquat ,
        bad line with no term:
        """)
        expect(parsed["ArcGIS"]?.joined(separator: "|") ?? "nil", "arc gis|arcjs", "colon + comma list parses")
        expect(parsed["Roscoe"] == [] ? "ok" : "\(String(describing: parsed["Roscoe"]))", "ok", "a bare word adds a term with no aliases")
        expect(parsed["Kumquat"]?.joined(separator: "|") ?? "nil", "kum kwat|cumquat", "whitespace and trailing commas are tolerated")
        expectInt(parsed.count, 4, "comments and blank lines are skipped; 'bad line with no term' is a term with no aliases")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spiel-vocab-\(UUID().uuidString).txt")
        try? "Roscoe: rosco, ross co\nArcGIS: arc jazz\n".write(to: tmp, atomically: true, encoding: .utf8)
        let merged = Glossary.load(userFile: tmp)
        expect(merged.apply(to: "tell rosco about arc jazz and geo json"), "tell Roscoe about ArcGIS and GeoJSON",
               "user aliases merge over the built-ins")
        expect(Glossary.load(userFile: URL(fileURLWithPath: "/nonexistent/vocab.txt")).count == Glossary().count ? "ok" : "differs", "ok",
               "a missing user file means built-ins only, no error")
        let tmpl = FileManager.default.temporaryDirectory.appendingPathComponent("spiel-vocab-tmpl-\(UUID().uuidString).txt")
        Glossary.ensureUserFile(at: tmpl)
        let roundTrip = Glossary.parse((try? String(contentsOf: tmpl, encoding: .utf8)) ?? "")
        expect(Glossary(entries: roundTrip).count == Glossary().count ? "ok" : "\(Glossary(entries: roundTrip).count) vs \(Glossary().count)", "ok",
               "the generated template round-trips to exactly the built-in glossary")
        try? FileManager.default.removeItem(at: tmp); try? FileManager.default.removeItem(at: tmpl)

        // The whole reason this is token-based and not a regex over prose.
        // Substring matching would turn "scarcity" into "scARcGISty".
        for word in ["scarcity", "flagol", "whispered", "esrious", "jawsome"] {
            expect(g.apply(to: word), word, "does not corrupt '\(word)'")
        }

        print("\nTextInserter — no Accessibility means no delivery, and it must say so")
        do {
            let ins = TextInserter()
            let out = ins.insert("hello from selftest", accessibilityTrusted: false)
            expect(out.success ? "success" : "failed", "failed",
                   "without Accessibility the insert reports FAILURE, never 'inserted via paste'")
            expect((out.detail ?? "").contains("Accessibility") ? "ok" : (out.detail ?? "nil"), "ok",
                   "the failure names Accessibility as the reason")
            expect((out.detail ?? "").contains("older build") ? "ok" : (out.detail ?? "nil"), "ok",
                   "the failure explains the stale-grant case")
            expect(NSPasteboard.general.string(forType: .string) ?? "", "hello from selftest",
                   "the text is left on the clipboard so nothing is lost")
        }

        print("\nTextInserter — AX readback verification folds typographic substitutions")
        expect(TextInserter.normalizedForVerification("Let\u{2019}s \u{201C}go\u{201D} \u{2014} now\u{2026}"),
               "Let's \"go\" - now...", "smart quotes, em dash and ellipsis fold to ASCII")
        expect(TextInserter.normalizedForVerification("a\u{00A0}b  c\td"), "a b c d",
               "non-breaking, repeated and tab whitespace collapse to one space")
        expect(TextInserter.normalizedForVerification("Case Kept"), "Case Kept", "case is preserved")
        expect(TextInserter.normalizedForVerification("unrelated autocorrect happened").contains(
                   TextInserter.normalizedForVerification("send the link")) ? "match" : "no match", "no match",
               "an unrelated value change does NOT verify an insertion (paste fallback must still fire)")

        print("\nVAD framing — Silero needs whole 4096-sample frames")
        // VadManager.chunkSize is 4096 and processChunk pads anything shorter by
        // repeating the last sample. AVAudioEngine taps at 1024 frames of the DEVICE
        // rate, which is ~341 samples once resampled to 16 kHz — so forwarding tap
        // buffers straight through fed Silero ~8% real audio and ~92% constant fill.
        expectInt(DictationSession.vadFrameSamples, 4096, "frame size matches VadManager.chunkSize")
        expect(String(format: "%.3f", DictationSession.vadFrameSeconds), "0.256",
               "frame is 256ms at 16kHz")
        // A realistic tap buffer must NOT be a whole frame — this is the trap.
        let typicalTap = 341
        expect(typicalTap >= DictationSession.vadFrameSamples ? "whole" : "partial", "partial",
               "a typical 16kHz tap buffer is smaller than one VAD frame")
        expectInt(DictationSession.vadFrameSamples / typicalTap, 12,
                  "~12 tap buffers accumulate into one VAD frame")

        print("\nSecurity — what leaves the process")
        do {
            // The dictated transcript is the sensitive asset in this app. These pin
            // the three places it can escape: the shared system log, the log file's
            // permissions, and the global pasteboard.
            // Logging is OFF by default and nothing is written until the user turns
            // it on. Proven on a temp file so the real Spiel.log — and the user's
            // persisted preference — are never touched.
            let freshDomain = "com.morehavoc.spiel.selftest-\(UUID().uuidString)"
            if let fresh = UserDefaults(suiteName: freshDomain) {
                expect(DiagnosticLog.isEnabled(in: fresh) ? "on" : "off", "off",
                       "a never-configured install has logging OFF")
                fresh.set("yes", forKey: DiagnosticLog.enabledKey)
                expect(DiagnosticLog.isEnabled(in: fresh) ? "on" : "off", "off",
                       "a non-bool preference value still reads as OFF, never on")
                fresh.set(true, forKey: DiagnosticLog.enabledKey)
                expect(DiagnosticLog.isEnabled(in: fresh) ? "on" : "off", "on",
                       "the persisted preference turns logging on")
                fresh.removePersistentDomain(forName: freshDomain)
            } else {
                expect("no suite", "suite", "could create a throwaway defaults domain")
            }

            let realURL = DiagnosticLog.url
            let persistedBefore = DiagnosticLog.defaults.object(forKey: DiagnosticLog.enabledKey) as? Bool
            let tmpLog = FileManager.default.temporaryDirectory
                .appendingPathComponent("spiel-selftest-\(UUID().uuidString).log")
            DiagnosticLog.url = tmpLog
            defer {
                DiagnosticLog.flush()
                DiagnosticLog.url = realURL
                DiagnosticLog.reloadEnabled()
                try? FileManager.default.removeItem(at: tmpLog)
                try? FileManager.default.removeItem(at: tmpLog.deletingPathExtension().appendingPathExtension("log.1"))
            }
            DiagnosticLog.setEnabled(false, persist: false)
            DiagnosticLog.write("selftest: must NOT land", sensitive: true)
            DiagnosticLog.write("selftest: must NOT land either")
            DiagnosticLog.flush()
            expect(FileManager.default.fileExists(atPath: tmpLog.path) ? "written" : "absent", "absent",
                   "with logging off, write() creates no file and appends nothing")

            DiagnosticLog.setEnabled(true, persist: false)
            DiagnosticLog.write("selftest permission probe")
            DiagnosticLog.flush()
            expect(FileManager.default.fileExists(atPath: tmpLog.path) ? "written" : "absent", "written",
                   "with logging on, write() lands (the gate is not stuck closed)")
            let perms = ((try? FileManager.default.attributesOfItem(atPath: tmpLog.path)[.posixPermissions]) as? NSNumber)?.intValue
            expect(perms.map { String($0, radix: 8) } ?? "nil", "600",
                   "Spiel.log is owner-only — it holds every transcript verbatim")
            let persistedAfter = DiagnosticLog.defaults.object(forKey: DiagnosticLog.enabledKey) as? Bool
            expect(persistedAfter == persistedBefore ? "untouched" : "changed", "untouched",
                   "selftest's in-process override never rewrites the user's persisted preference")

            expect(TextInserter.concealedType.rawValue, "org.nspasteboard.ConcealedType",
                   "the concealed-clipboard marker is the exact UTI clipboard managers honour")
            expect(TextInserter.pasteboardRescueTTL > 0 && TextInserter.pasteboardRescueTTL <= 300 ? "ok" : "\(TextInserter.pasteboardRescueTTL)", "ok",
                   "a rescue transcript is taken back off the clipboard, and within 5 minutes")

            // An oversized vocabulary file must degrade to built-ins, not be read.
            let big = FileManager.default.temporaryDirectory.appendingPathComponent("spiel-vocab-big-\(UUID().uuidString).txt")
            let filler = String(repeating: "Padding\(UUID().uuidString): pad pad pad\n", count: 12_000)
            try? filler.write(to: big, atomically: true, encoding: .utf8)
            let bigSize = ((try? FileManager.default.attributesOfItem(atPath: big.path)[.size]) as? Int) ?? 0
            expect(bigSize > Glossary.maxUserFileBytes ? "ok" : "\(bigSize)", "ok",
                   "the oversize fixture really is over the cap (guards against a vacuous test)")
            expect(Glossary.load(userFile: big).count == Glossary().count ? "ok" : "differs", "ok",
                   "an oversized vocabulary file is ignored, falling back to built-ins")
            try? FileManager.default.removeItem(at: big)

            // The rescue clear must be keyed on CONTENT: take back our own transcript,
            // never take back something he copied afterwards.
            let pb = NSPasteboard.general
            pb.clearContents(); pb.setString("spiel transcript fixture", forType: .string)
            TextInserter.clearIfStillOurs("spiel transcript fixture")
            expect(pb.string(forType: .string) ?? "nil", "nil",
                   "the rescue clear takes our own transcript back off the clipboard")
            pb.clearContents(); pb.setString("something he copied himself", forType: .string)
            TextInserter.clearIfStillOurs("spiel transcript fixture")
            expect(pb.string(forType: .string) ?? "nil", "something he copied himself",
                   "the rescue clear NEVER eats a clipboard he wrote after us")

            // Every transcript put on the global pasteboard carries the concealed
            // marker, not just the Secure-Input one. Driven through the real
            // no-Accessibility rescue path.
            pb.clearContents()
            let rescue = TextInserter()
            _ = rescue.insert("concealment fixture", accessibilityTrusted: false)
            expect(pb.string(forType: .string) ?? "nil", "concealment fixture",
                   "a rescue transcript really is left on the clipboard (guards against a vacuous next check)")
            expect(pb.types?.contains(TextInserter.concealedType) == true ? "ok" : "\(pb.types ?? [])", "ok",
                   "every transcript on the pasteboard is marked concealed, not only under Secure Input")
            TextInserter.clearIfStillOurs("concealment fixture")

            // A FIFO stats small and reads forever; the cap must be applied to the
            // opened descriptor, not to a path that was stat'd separately.
            let fifo = FileManager.default.temporaryDirectory.appendingPathComponent("spiel-vocab-fifo-\(UUID().uuidString)")
            if mkfifo(fifo.path, 0o600) == 0 {
                let opened = open(fifo.path, O_RDWR | O_NONBLOCK)  // keep a writer so the read side does not block
                expect(Glossary.load(userFile: fifo).count == Glossary().count ? "ok" : "differs", "ok",
                       "a non-regular vocabulary file (FIFO) is refused, not read")
                if opened >= 0 { close(opened) }
                try? FileManager.default.removeItem(at: fifo)
            }

            let longAlias = String(repeating: "a", count: Glossary.maxAliasLength + 1)
            let capped = Glossary.parse("Term: ok alias, \(longAlias)\n")
            expect(capped["Term"]?.joined(separator: "|") ?? "nil", "ok alias",
                   "an absurdly long alias is dropped, a normal one survives")
        }

        // MARK: Open at Login
        // Nothing here registers anything — these drive the pure decision helpers
        // plus the read-only state, so running selftest never touches the user's
        // real login items.
        print("\nOpen at Login — the checkmark must never outrank what macOS says")
        do {
            let translocated = "/private/var/folders/xy/T/AppTranslocation/A1B2/d/Spiel.app"
            expect(LaunchAtLogin.isTranslocated(bundlePath: translocated) ? "yes" : "no", "yes",
                   "a Gatekeeper-translocated copy is recognised")
            expect(LaunchAtLogin.isTranslocated(bundlePath: "/Applications/Spiel.app") ? "yes" : "no", "no",
                   "a normally installed copy is NOT called translocated (guards against a blanket refusal)")

            // Registering from a translocated copy would report success and then never
            // launch, because the path is gone at the next login. It must be refused.
            expect(LaunchAtLogin.blocker(bundleIdentifier: "com.morehavoc.spiel", bundlePath: translocated) == nil ? "allowed" : "blocked",
                   "blocked", "registration is refused from a translocated copy")
            expect(LaunchAtLogin.blocker(bundleIdentifier: "com.morehavoc.spiel", bundlePath: "/Applications/Spiel.app") ?? "nil",
                   "nil", "registration is allowed from /Applications")
            expect(LaunchAtLogin.blocker(bundleIdentifier: nil, bundlePath: "/usr/local/bin/spiel-cli") == nil ? "allowed" : "blocked",
                   "blocked", "an unbundled binary cannot register a login item")

            expect(LaunchAtLogin.locationNote(bundlePath: "/Applications/Spiel.app") ?? "nil", "nil",
                   "no location warning for /Applications")
            expect(LaunchAtLogin.locationNote(bundlePath: "/Users/x/Downloads/Spiel.app")?.contains("Downloads") == true ? "ok" : "missing",
                   "ok", "living in Downloads is called out by name — the next build replaces it")
            expect(LaunchAtLogin.locationNote(bundlePath: "/Users/x/Desktop/Spiel.app") == nil ? "nil" : "warned",
                   "warned", "any location outside /Applications gets a warning")

            expect(LaunchAtLogin.describe(.enabled) == .on ? "on" : "other", "on",
                   "macOS .enabled reads as ON")
            expect(LaunchAtLogin.describe(.notRegistered) == .off ? "off" : "other", "off",
                   "macOS .notRegistered reads as off")
            expect(LaunchAtLogin.describe(.requiresApproval) == .requiresApproval ? "approval" : "other", "approval",
                   "a login item the user switched off in System Settings is NOT reported as on")
            expect(LaunchAtLogin.describe(.requiresApproval).isChecked ? "checked" : "unchecked", "unchecked",
                   "only .on draws a checkmark — an approval-blocked item must not look enabled")
            // Measured on a real self-signed bundle: a never-registered app reports
            // .notFound, and register() succeeds from there. It is the first-launch
            // state, so it must be a clickable off — not a greyed-out "unavailable",
            // which would kill the feature for every new install.
            expect(LaunchAtLogin.describe(.notFound) == .off ? "off" : "other", "off",
                   "a never-registered app (.notFound) is a clickable off, not unavailable")
            expect(LaunchAtLogin.describe(.notFound).isChecked ? "checked" : "unchecked", "unchecked",
                   "…and it still draws no checkmark")

            // This binary is spiel-cli: no bundle identifier, so the live read must
            // report unavailable rather than inventing an answer.
            if case .unavailable = LaunchAtLogin.state() {
                expect("unavailable", "unavailable", "spiel-cli reports Open at Login as unavailable, not off or on")
            } else {
                expect(LaunchAtLogin.label(LaunchAtLogin.state()), "unavailable",
                       "spiel-cli reports Open at Login as unavailable, not off or on")
            }
            expect(LaunchAtLogin.label(.on), "on", "the label for on")
            expect(LaunchAtLogin.label(.requiresApproval).contains("System Settings") ? "ok" : "missing", "ok",
                   "the blocked label names where to fix it")
            expect(LaunchAtLogin.settingsURL.scheme ?? "nil", "x-apple.systempreferences",
                   "the Login Items deep link is a System Settings URL")
        }

        await pipelineTests()
        await listenTimingTests()
        transcriptDocumentTests()
        transcriptStoreTests()
        hotkeyRoutingTests()
        listenSourceRules()

        print("\n\(checks - failures)/\(checks) checks passed")
        if failures > 0 {
            print("FAILED: \(failures)")
            return 1
        }
        print("OK")
        return 0
    }
}
