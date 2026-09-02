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
    func prepare() async throws {}
    func transcribe(samples: [Float]) async throws -> String {
        calls += 1
        samplesSeen += samples.count
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

        // Round 3 — two bursts, ordered.
        await session.reset()
        feedLikeMic(session, burst(speech: 0.8) + burst(speech: 0.8))
        let r3 = await session.finishWithReport()
        expect(r3.text, "word3 word4", "two bursts become two segments in speech order")
        expectInt(r3.segments, 2, "round 3: two segments")

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
            let early = await a.accept(.init(index: 1, text: "second sentence", isFinal: true))
            expect(early, "", "index 1 is held until index 0 arrives")
            let released = await a.accept(.init(index: 0, text: "first sentence", isFinal: true))
            expect(released, "first sentence second sentence", "out-of-order arrival reassembles in speech order")
            expect(await a.text(), "first sentence second sentence", "full transcript is in speech order")
        }

        do {
            let a = TranscriptAssembler()
            expect(await a.accept(.init(index: 0, text: "one", isFinal: true)), "one", "contiguous index 0 releases immediately")
            expect(await a.accept(.init(index: 1, text: "two", isFinal: true)), "two", "contiguous index 1 releases immediately")
        }

        // A failed segment must not swallow everything spoken after it.
        do {
            let a = TranscriptAssembler()
            _ = await a.accept(.init(index: 1, text: "kept", isFinal: true))
            expect(await a.accept(.init(index: 0, text: "", isFinal: true)), "kept",
                   "an empty placeholder does not stall the gate")
        }

        // A permanently missing segment must not silently eat the rest.
        do {
            let a = TranscriptAssembler()
            _ = await a.accept(.init(index: 3, text: "orphan", isFinal: true))
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

        // The whole reason this is token-based and not a regex over prose.
        // Substring matching would turn "scarcity" into "scARcGISty".
        for word in ["scarcity", "flagol", "whispered", "esrious", "jawsome"] {
            expect(g.apply(to: word), word, "does not corrupt '\(word)'")
        }

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
