# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Spiel is a macOS desktop app for voice-to-text dictation using OpenAI's Whisper API. Users press a hotkey, speak naturally, see real-time transcription with optional AI cleanup, and have text automatically inserted into any active application.

**Status**: Design phase - `design.md` contains the full specification, no implementation yet.

## Build Commands

```bash
npm install              # Install dependencies
npm run electron:dev     # Development with hot reload (Vite + Electron)
npm run dev              # Vite dev server only
npm run build:mac        # Production build for macOS
npm run typecheck        # TypeScript type checking
```

Output: `release/` directory with `.dmg` installer

## Architecture

### Electron IPC Pattern

- **Main process** (`electron/main.ts`): Handles system-level tasks (global hotkeys via `uiohook-napi`, clipboard, window management, API calls)
- **Renderer process** (`src/`): React 18 + Zustand for UI and state
- **Preload bridge** (`electron/preload.ts`): Context-isolated IPC between main and renderer

### Core Services (electron/services/)

| Service | Purpose |
|---------|---------|
| `hotkeyManager.ts` | Double-tap Control or F5 detection using `uiohook-napi` |
| `audioRecorder.ts` | MediaRecorder in renderer, sends chunks to main via IPC |
| `vadProcessor.ts` | Amplitude-based silence detection (~900ms threshold) |
| `whisperApi.ts` | OpenAI Whisper API client |
| `aiCleanup.ts` | Optional GPT-4o-mini post-processing |
| `textInserter.ts` | Clipboard + Cmd+V paste or character-by-character typing |
| `windowManager.ts` | Tray icon, frameless floating bar, settings window |

### Key Technical Decisions

- Audio: 16000 Hz sample rate, WebM/Opus format (Whisper standard)
- VAD sends chunks on ~900ms silence, minimum 500ms speech
- API key encrypted via Electron's `safeStorage`
- Text insertion saves/restores clipboard content
- Context isolation enabled, nodeIntegration disabled

### IPC Channels

```
Main → Renderer: recording:state-change, recording:transcript-update, recording:waveform-data
Renderer → Main: recording:toggle, settings:get, settings:set, audio:chunk
```

## Dependencies

- `uiohook-napi` for low-level global hotkey detection
- `robotjs` for simulating keyboard (Cmd+V paste)
- `electron-store` for persistent settings
- `openai` SDK for Whisper and GPT-4o-mini

## macOS Requirements

The app requires entitlements for:
- Microphone access
- AppleEvents (for text insertion into other apps)
- JIT compilation

See `build/entitlements.mac.plist` in the design spec.
