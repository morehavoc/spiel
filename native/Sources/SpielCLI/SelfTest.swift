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

    /// Feed like the microphone does: ~341-sample tap buffers, synchronously.
    static func feedLikeMic(_ session: DictationSession, _ samples: [Float]) {
        var i = 0
        while i < samples.count {
            let end = min(i + 341, samples.count)
            session.sink.submit(Array(samples[i..<end]))
            i = end
        }
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
            if case .unavailable = LaunchAtLogin.describe(.notFound) {
                expect("unavailable", "unavailable", "an unknown-to-macOS registration reads as unavailable, never off")
            } else {
                expect("\(LaunchAtLogin.describe(.notFound))", "unavailable",
                       "an unknown-to-macOS registration reads as unavailable, never off")
            }

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

        print("\n\(checks - failures)/\(checks) checks passed")
        if failures > 0 {
            print("FAILED: \(failures)")
            return 1
        }
        print("OK")
        return 0
    }
}
