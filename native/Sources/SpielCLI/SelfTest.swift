import Foundation
import SpielCore

/// Assertions for the pure logic — the two v1 bugs that were silent, plus the
/// component most likely to cause new damage.
///
/// These live in the CLI rather than a test target because this machine has Command
/// Line Tools only, and BOTH XCTest and swift-testing ship with Xcode.app. Running
/// them as a plain executable means they work on any Mac with the toolchain, and
/// Christopher can run them himself: `spiel-cli selftest`.
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

        print("\n\(checks - failures)/\(checks) checks passed")
        if failures > 0 {
            print("FAILED: \(failures)")
            return 1
        }
        print("OK")
        return 0
    }
}
