# Spiel v2 — native

A ground-up Swift rewrite of Spiel's engine, living alongside the original Electron
app on the `v2-native` branch. Nothing in `electron/` or `src/` was touched.

## Why a rewrite rather than an engine swap

The three long-standing complaints about v1 are all **architecture**, not model
quality, so changing the transcription API inside the Electron app would have fixed
none of them:

| Symptom | v1 cause | v2 fix |
|---|---|---|
| "It doesn't always turn on" | `globalShortcut.register()` returning `false` was handled with a `console.error` and a `// Could show an alert` TODO. Registration is system-exclusive, so a conflict left a live-looking menu bar with a dead hotkey. | `HotkeyManager` surfaces every failure: warning icon in the menu bar, a notification, the reason in the menu, and a one-click "Try F5 instead". |
| "Doesn't work right in some apps" | `osascript … keystroke "v"` per insertion, refocus by app *display name*, clipboard restored on a flat 100 ms timer, and only `readText()` saved — so an image on the clipboard was destroyed. | Two-tier insert: Accessibility `kAXSelectedTextAttribute` **with read-back verification**, falling back to `CGEvent` Cmd+V. Refocus by `NSRunningApplication` (pid). All pasteboard flavors preserved. Secure Input detected and reported. |
| CPU | A `requestAnimationFrame` loop at ~60 Hz calling a Zustand setter every tick, re-rendering the whole React tree inside a transparent `backdrop-blur` always-on-top window. Plus a renderer process kept resident forever after first use. | No Electron. Plain `NSPanel`, one custom view, redraw throttled to 15 Hz, no blur. VAD moved off the render loop entirely. |

Two accuracy bugs are also fixed:

* **Out-of-order sentences.** v1 appended transcription results in *completion* order,
  so two concurrent segments could swap. `TranscriptAssembler` stamps each segment at
  capture time and only releases a contiguous prefix.
* **Stale audio on every segment.** v1 saved the session's first 100 ms WebM chunk and
  prepended it to every later segment so the file would decode — shipping a duplicated
  fragment of the session opening each time, with a non-monotonic timeline. It also
  cleared its chunk buffer the instant speech was detected, discarding the start of the
  word. v2 works in raw `[Float]` PCM, so there is no container to repair, and keeps a
  300 ms pre-roll so onsets survive.

## Layout

```
native/
├── Package.swift
├── Sources/
│   ├── SpielCore/          # engine-agnostic library
│   │   ├── Transcriber.swift          # protocol + result types
│   │   ├── ParakeetTranscriber.swift  # FluidAudio / Parakeet TDT on the ANE
│   │   ├── AppleSpeechTranscriber.swift # macOS 26 SpeechAnalyzer
│   │   ├── AudioCapture.swift         # AVAudioEngine → 16 kHz mono float
│   │   ├── DictationSession.swift     # VAD → segment → transcribe → assemble
│   │   ├── TranscriptAssembler.swift  # speech-order reassembly
│   │   ├── Glossary.swift             # custom-vocabulary post-pass
│   │   └── TextInserter.swift         # AX + CGEvent insertion
│   ├── SpielCLI/           # headless harness (spiel-cli)
│   └── SpielApp/           # menu-bar app
└── scripts/bundle.sh       # → build/Spiel.app
```

## Engine choice

Primary is **Parakeet TDT via FluidAudio** (Apache 2.0), running on the Neural Engine.
On Argmax's M4 Mac mini benchmark Parakeet-v2 measured 11.7% WER at a 359x speed
factor — the only engine there that beats Apple's `SpeechTranscriber` (14.0% / 70x) on
accuracy *and* speed at once. FluidAudio's own figure is ~190x realtime on an M4 Pro.

**Apple `SpeechAnalyzer`** (macOS 26+) is the fallback and needs no third-party
download. The app degrades to it automatically if Parakeet's weights can't be fetched.

Parakeet weights come from HuggingFace on first run (hundreds of MB) and are cached by
FluidAudio. They are never committed.

## Custom vocabulary

Argmax note that Apple's new `SpeechTranscriber` **dropped** the Custom Vocabulary
feature its older API had, and Parakeet has no biasing hook either. So `Glossary` is a
separate stage downstream of whichever engine ran, carrying ArcGIS, GeoJSON, Esri,
dymaptic, AGOL, Survey123, Whisperframe and friends.

It is deliberately **not** a regex over prose: matching is whole-token on a fixed alias
list, longest-span-first. Substring matching would turn "scarcity" into "scARcGISty".

## Build

```bash
cd native
swift build -c release          # library + CLI + app
./scripts/bundle.sh             # → build/Spiel.app
```

Command Line Tools are sufficient; no Xcode.app required.

## CLI

```bash
spiel-cli doctor                        # environment + permission report
spiel-cli transcribe file.wav           # file → text, with timing
spiel-cli transcribe file.wav --engine apple
spiel-cli glossary "publish the arc gis layer as geo json"
spiel-cli live --seconds 8              # mic → text (needs mic permission)
```

The CLI exists so transcription can be proven without a GUI, without the microphone,
and without anyone present to click a TCC prompt.
