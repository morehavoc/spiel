# CLAUDE.md

Spiel is a native Swift (SwiftPM) macOS menu-bar dictation app. All code lives in `native/`;
transcription runs on the Mac (Parakeet on the Neural Engine via FluidAudio, Apple
`SpeechAnalyzer` as a fallback). No network or API key is needed to dictate.

- What it does and how it is laid out: `native/README.md`
- Releasing (GitHub Actions, Developer ID, notarization, Sparkle): `native/RELEASING.md`
- Build a dev app: `native/scripts/bundle.sh release` → `native/build/Spiel.app`
- Tests: `cd native && swift build -c release --product spiel-cli && .build/release/spiel-cli selftest`
- The version lives only in `native/Sources/SpielCore/Version.swift` (`build` must grow every release)

The original Electron app (v1, OpenAI Whisper) was removed in 2026-10; it is in git history
before that commit.
