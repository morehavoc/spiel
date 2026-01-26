# Spiel - Project Specification

*"Give your spiel, get it in text."*

## Overview

**Spiel** is an open-source macOS desktop app for voice-to-text dictation using OpenAI's Whisper API. Users provide their own API key and get a seamless experience: press a hotkey, speak naturally, see transcription appear in real-time, and have it automatically inserted into any active application.

## Core User Flow

1. User presses hotkey (double-tap Control or F5)
2. Floating recording bar appears showing "Recording..."
3. User speaks naturally
4. As they pause (~1 second), chunks are sent to Whisper API
5. Transcribed text appears in the floating bar progressively
6. User presses hotkey again to stop
7. (Optional) AI cleanup pass on full transcript
8. Text is inserted into the previously active application

## Tech Stack

- **Framework**: Electron 36+
- **Frontend**: React 18 + TypeScript
- **Build Tool**: Vite
- **Styling**: Tailwind CSS
- **State Management**: Zustand (lightweight)
- **Storage**: electron-store (settings), better-sqlite3 (optional history)
- **Packaging**: electron-builder
- **Desktop Automation**: @jitsi/oboejs (modern robotjs alternative) OR robotjs

## Project Structure

```
spiel/
├── electron/
│   ├── main.ts                 # Main process entry
│   ├── preload.ts              # Context bridge
│   ├── services/
│   │   ├── hotkeyManager.ts    # Global hotkey detection (double-tap, F5)
│   │   ├── audioRecorder.ts    # Audio capture coordination
│   │   ├── vadProcessor.ts     # Voice activity detection
│   │   ├── whisperApi.ts       # OpenAI Whisper API client
│   │   ├── aiCleanup.ts        # GPT text cleanup (optional)
│   │   ├── textInserter.ts     # Clipboard + paste / typing
│   │   └── windowManager.ts    # Floating bar, tray, focus tracking
│   ├── store.ts                # Persistent settings
│   └── ipc.ts                  # IPC channel definitions
├── src/
│   ├── main.tsx                # React entry
│   ├── App.tsx                 # Router between windows
│   ├── windows/
│   │   ├── RecordingBar.tsx    # Floating recording UI
│   │   └── Settings.tsx        # Settings window
│   ├── components/
│   │   ├── Waveform.tsx        # Audio visualization
│   │   ├── TranscriptDisplay.tsx # Live transcript with typewriter effect
│   │   ├── StatusIndicator.tsx # Recording/processing/idle states
│   │   └── ApiKeyInput.tsx     # Secure API key entry
│   ├── hooks/
│   │   ├── useRecordingState.ts
│   │   └── useTranscription.ts
│   ├── stores/
│   │   └── appStore.ts         # Zustand store
│   └── styles/
│       └── index.css           # Tailwind imports
├── resources/
│   ├── icon.icns               # macOS app icon
│   ├── tray-icon.png           # Menu bar icon (22x22)
│   └── tray-icon-recording.png # Recording state icon
├── package.json
├── tsconfig.json
├── tsconfig.node.json
├── vite.config.ts
├── electron-builder.json
├── tailwind.config.js
└── README.md
```

## Detailed Component Specifications

### 1. Hotkey Manager (`electron/services/hotkeyManager.ts`)

**Requirements**:
- Support double-tap Control key (left or right)
- Support F5 / Dictation key
- Support custom hotkey combos (Cmd+Shift+Space, etc.)
- Configurable double-tap threshold (default: 300ms)

**Implementation**:
```typescript
import { globalShortcut, BrowserWindow } from 'electron';
import { uIOhook, UiohookKey } from 'uiohook-napi'; // For double-tap detection

interface HotkeyConfig {
  type: 'double-tap' | 'single-key' | 'combo';
  key: string;
  modifiers?: string[];
  doubleTapThreshold?: number; // ms
}

class HotkeyManager {
  private lastControlPress = 0;
  private config: HotkeyConfig;
  private onTrigger: () => void;

  constructor(config: HotkeyConfig, onTrigger: () => void) {
    this.config = config;
    this.onTrigger = onTrigger;
  }

  start() {
    if (this.config.type === 'double-tap') {
      this.setupDoubleTap();
    } else if (this.config.type === 'single-key') {
      this.setupSingleKey();
    } else {
      this.setupCombo();
    }
  }

  private setupDoubleTap() {
    uIOhook.on('keyup', (e) => {
      if (e.keycode === UiohookKey.Ctrl || e.keycode === UiohookKey.CtrlRight) {
        const now = Date.now();
        if (now - this.lastControlPress < (this.config.doubleTapThreshold || 300)) {
          this.onTrigger();
          this.lastControlPress = 0; // Reset
        } else {
          this.lastControlPress = now;
        }
      }
    });
    uIOhook.start();
  }

  private setupSingleKey() {
    // For F5 key - need to check if macOS dictation is disabled
    globalShortcut.register('F5', this.onTrigger);
  }

  private setupCombo() {
    const combo = this.config.modifiers?.join('+') + '+' + this.config.key;
    globalShortcut.register(combo, this.onTrigger);
  }

  stop() {
    globalShortcut.unregisterAll();
    uIOhook.stop();
  }
}
```

**Dependencies**: `uiohook-napi` (for low-level key detection)

### 2. Audio Recorder (`electron/services/audioRecorder.ts`)

**Requirements**:
- Capture microphone audio using Web Audio API (in renderer)
- Stream audio data to main process for VAD processing
- Support configurable sample rate (default: 16000 Hz for Whisper)
- Output format: WebM or WAV

**Implementation approach**:
- Renderer process: MediaRecorder API captures audio
- Send audio chunks to main process via IPC
- Main process coordinates VAD and API calls

```typescript
// In renderer (preload-exposed)
class AudioRecorder {
  private mediaRecorder: MediaRecorder | null = null;
  private audioContext: AudioContext | null = null;
  private analyser: AnalyserNode | null = null;
  private stream: MediaStream | null = null;
  private chunks: Blob[] = [];

  async start(): Promise<void> {
    this.stream = await navigator.mediaDevices.getUserMedia({ 
      audio: {
        channelCount: 1,
        sampleRate: 16000,
        echoCancellation: true,
        noiseSuppression: true,
      } 
    });

    // Setup analyser for waveform visualization
    this.audioContext = new AudioContext({ sampleRate: 16000 });
    const source = this.audioContext.createMediaStreamSource(this.stream);
    this.analyser = this.audioContext.createAnalyser();
    this.analyser.fftSize = 256;
    source.connect(this.analyser);

    // Setup recorder
    this.mediaRecorder = new MediaRecorder(this.stream, {
      mimeType: 'audio/webm;codecs=opus'
    });

    this.mediaRecorder.ondataavailable = (e) => {
      if (e.data.size > 0) {
        this.chunks.push(e.data);
        // Send to main process for VAD analysis
        window.electronAPI.sendAudioChunk(e.data);
      }
    };

    // Capture data every 100ms for responsive VAD
    this.mediaRecorder.start(100);
  }

  getWaveformData(): Uint8Array {
    if (!this.analyser) return new Uint8Array(0);
    const data = new Uint8Array(this.analyser.frequencyBinCount);
    this.analyser.getByteTimeDomainData(data);
    return data;
  }

  stop(): Blob {
    this.mediaRecorder?.stop();
    this.stream?.getTracks().forEach(track => track.stop());
    const blob = new Blob(this.chunks, { type: 'audio/webm' });
    this.chunks = [];
    return blob;
  }
}
```

### 3. VAD Processor (`electron/services/vadProcessor.ts`)

**Requirements**:
- Detect silence/speech using amplitude threshold
- Configurable silence duration threshold (default: 900ms)
- Emit events when speech segment ends (for chunked transcription)
- Simple amplitude-based detection (no ML required for v1)

```typescript
interface VADConfig {
  silenceThreshold: number;     // 0.01 = 1% of max amplitude
  silenceDuration: number;      // ms of silence before chunk end (default: 900)
  minChunkDuration: number;     // minimum audio to send (default: 500ms)
}

class VADProcessor {
  private config: VADConfig;
  private silenceStart: number | null = null;
  private chunkStart: number = Date.now();
  private audioBuffer: ArrayBuffer[] = [];
  
  constructor(config: Partial<VADConfig> = {}) {
    this.config = {
      silenceThreshold: config.silenceThreshold ?? 0.01,
      silenceDuration: config.silenceDuration ?? 900,
      minChunkDuration: config.minChunkDuration ?? 500,
    };
  }

  processAudioData(
    audioData: Float32Array, 
    onChunkReady: (audio: Blob) => void
  ): void {
    const amplitude = this.calculateAmplitude(audioData);
    const now = Date.now();
    
    if (amplitude < this.config.silenceThreshold) {
      // Silence detected
      if (!this.silenceStart) {
        this.silenceStart = now;
      }
      
      const silenceDuration = now - this.silenceStart;
      const chunkDuration = now - this.chunkStart;
      
      if (
        silenceDuration >= this.config.silenceDuration &&
        chunkDuration >= this.config.minChunkDuration &&
        this.audioBuffer.length > 0
      ) {
        // End of speech segment - emit chunk
        const chunk = this.flushBuffer();
        onChunkReady(chunk);
        this.chunkStart = now;
      }
    } else {
      // Speech detected
      this.silenceStart = null;
      this.audioBuffer.push(audioData.buffer);
    }
  }

  private calculateAmplitude(data: Float32Array): number {
    let sum = 0;
    for (let i = 0; i < data.length; i++) {
      sum += Math.abs(data[i]);
    }
    return sum / data.length;
  }

  private flushBuffer(): Blob {
    const blob = new Blob(this.audioBuffer, { type: 'audio/webm' });
    this.audioBuffer = [];
    return blob;
  }

  // Call when recording stops to get any remaining audio
  flush(): Blob | null {
    if (this.audioBuffer.length === 0) return null;
    return this.flushBuffer();
  }
}
```

### 4. Whisper API Client (`electron/services/whisperApi.ts`)

**Requirements**:
- Send audio chunks to OpenAI Whisper API
- Handle API errors gracefully
- Support language hints (optional)
- Return transcription text

```typescript
import FormData from 'form-data';
import fetch from 'node-fetch';

interface WhisperConfig {
  apiKey: string;
  model: 'whisper-1' | 'gpt-4o-transcribe' | 'gpt-4o-mini-transcribe';
  language?: string; // ISO-639-1 code
  prompt?: string;   // Context hint
}

interface TranscriptionResult {
  text: string;
  duration?: number;
}

class WhisperApiClient {
  private config: WhisperConfig;

  constructor(config: WhisperConfig) {
    this.config = config;
  }

  async transcribe(audioBlob: Blob): Promise<TranscriptionResult> {
    const formData = new FormData();
    
    // Convert Blob to Buffer for node-fetch
    const arrayBuffer = await audioBlob.arrayBuffer();
    const buffer = Buffer.from(arrayBuffer);
    
    formData.append('file', buffer, {
      filename: 'audio.webm',
      contentType: 'audio/webm',
    });
    formData.append('model', this.config.model);
    
    if (this.config.language) {
      formData.append('language', this.config.language);
    }
    
    if (this.config.prompt) {
      formData.append('prompt', this.config.prompt);
    }

    const response = await fetch('https://api.openai.com/v1/audio/transcriptions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${this.config.apiKey}`,
      },
      body: formData,
    });

    if (!response.ok) {
      const error = await response.json();
      throw new Error(`Whisper API error: ${error.error?.message || response.statusText}`);
    }

    const result = await response.json();
    return { text: result.text };
  }
}
```

### 5. AI Cleanup Service (`electron/services/aiCleanup.ts`)

**Requirements**:
- Optional post-processing of transcription
- Fix grammar, remove filler words, improve punctuation
- Use GPT-4o-mini (fast and cheap)
- Configurable: on/off globally

```typescript
import OpenAI from 'openai';

interface CleanupConfig {
  apiKey: string;
  enabled: boolean;
}

class AICleanupService {
  private openai: OpenAI;
  private enabled: boolean;

  constructor(config: CleanupConfig) {
    this.openai = new OpenAI({ apiKey: config.apiKey });
    this.enabled = config.enabled;
  }

  async cleanup(rawText: string): Promise<string> {
    if (!this.enabled || !rawText.trim()) {
      return rawText;
    }

    const response = await this.openai.chat.completions.create({
      model: 'gpt-4o-mini',
      messages: [
        {
          role: 'system',
          content: `You are a transcription cleanup assistant. Clean up the following dictated text:
- Fix grammar and punctuation
- Remove filler words (um, uh, like, you know)
- Fix obvious transcription errors
- Maintain the original meaning and tone
- Do NOT add or remove content
- Do NOT change the style or formality level
- Return ONLY the cleaned text, no explanations`
        },
        {
          role: 'user',
          content: rawText
        }
      ],
      temperature: 0.3,
      max_tokens: 4096,
    });

    return response.choices[0]?.message?.content || rawText;
  }
}
```

### 6. Text Inserter (`electron/services/textInserter.ts`)

**Requirements**:
- Primary: Clipboard + simulate Cmd+V
- Alternative: Type character-by-character
- Save and restore previous clipboard content
- Configurable insertion method

```typescript
import { clipboard } from 'electron';
import robot from 'robotjs';

type InsertionMethod = 'paste' | 'type';

interface InserterConfig {
  method: InsertionMethod;
  typeDelay?: number;        // ms between characters for 'type' method
  restoreClipboard?: boolean; // Save/restore clipboard content
}

class TextInserter {
  private config: InserterConfig;
  private savedClipboard: string | null = null;

  constructor(config: InserterConfig) {
    this.config = {
      method: config.method ?? 'paste',
      typeDelay: config.typeDelay ?? 5,
      restoreClipboard: config.restoreClipboard ?? true,
    };
  }

  async insert(text: string): Promise<void> {
    if (this.config.method === 'paste') {
      await this.insertViaPaste(text);
    } else {
      await this.insertViaTyping(text);
    }
  }

  private async insertViaPaste(text: string): Promise<void> {
    // Save current clipboard if configured
    if (this.config.restoreClipboard) {
      this.savedClipboard = clipboard.readText();
    }

    // Write text to clipboard
    clipboard.writeText(text);

    // Small delay to ensure clipboard is ready
    await this.delay(50);

    // Simulate Cmd+V (macOS) or Ctrl+V (Windows/Linux)
    const modifier = process.platform === 'darwin' ? 'command' : 'control';
    robot.keyTap('v', modifier);

    // Restore clipboard after a delay
    if (this.config.restoreClipboard && this.savedClipboard !== null) {
      await this.delay(100);
      clipboard.writeText(this.savedClipboard);
      this.savedClipboard = null;
    }
  }

  private async insertViaTyping(text: string): Promise<void> {
    robot.setKeyboardDelay(this.config.typeDelay!);
    robot.typeString(text);
  }

  private delay(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }
}
```

### 7. Window Manager (`electron/services/windowManager.ts`)

**Requirements**:
- Create tray icon with menu
- Create floating recording bar (frameless, always-on-top)
- Track previously focused window for text insertion
- Handle window positioning and dragging

```typescript
import { 
  app, 
  BrowserWindow, 
  Tray, 
  Menu, 
  nativeImage,
  screen 
} from 'electron';
import path from 'path';

class WindowManager {
  private tray: Tray | null = null;
  private recordingBar: BrowserWindow | null = null;
  private settingsWindow: BrowserWindow | null = null;
  private previousActiveWindow: number | null = null; // For focus restoration

  createTray() {
    const iconPath = path.join(__dirname, '../../resources/tray-icon.png');
    this.tray = new Tray(nativeImage.createFromPath(iconPath));
    
    const contextMenu = Menu.buildFromTemplate([
      { label: 'Start Recording', click: () => this.emit('toggle-recording') },
      { type: 'separator' },
      { label: 'Settings', click: () => this.openSettings() },
      { type: 'separator' },
      { label: 'Quit', click: () => app.quit() }
    ]);
    
    this.tray.setContextMenu(contextMenu);
    this.tray.setToolTip('Whisper Dictation');
  }

  setTrayRecording(isRecording: boolean) {
    const iconName = isRecording ? 'tray-icon-recording.png' : 'tray-icon.png';
    const iconPath = path.join(__dirname, '../../resources', iconName);
    this.tray?.setImage(nativeImage.createFromPath(iconPath));
  }

  createRecordingBar() {
    const { width: screenWidth } = screen.getPrimaryDisplay().workAreaSize;
    
    this.recordingBar = new BrowserWindow({
      width: 300,
      height: 80,
      x: Math.round(screenWidth / 2 - 150),
      y: 100,
      frame: false,
      transparent: true,
      alwaysOnTop: true,
      skipTaskbar: true,
      resizable: false,
      hasShadow: true,
      webPreferences: {
        preload: path.join(__dirname, '../preload.js'),
        contextIsolation: true,
        nodeIntegration: false,
      }
    });

    // Load the recording bar UI
    if (process.env.NODE_ENV === 'development') {
      this.recordingBar.loadURL('http://localhost:5173/#/recording-bar');
    } else {
      this.recordingBar.loadFile('dist/index.html', { hash: '/recording-bar' });
    }

    // Enable dragging
    this.recordingBar.setMovable(true);
  }

  showRecordingBar() {
    if (!this.recordingBar) {
      this.createRecordingBar();
    }
    this.recordingBar?.show();
  }

  hideRecordingBar() {
    this.recordingBar?.hide();
  }

  openSettings() {
    if (this.settingsWindow) {
      this.settingsWindow.focus();
      return;
    }

    this.settingsWindow = new BrowserWindow({
      width: 500,
      height: 600,
      title: 'Whisper Dictation Settings',
      webPreferences: {
        preload: path.join(__dirname, '../preload.js'),
        contextIsolation: true,
        nodeIntegration: false,
      }
    });

    if (process.env.NODE_ENV === 'development') {
      this.settingsWindow.loadURL('http://localhost:5173/#/settings');
    } else {
      this.settingsWindow.loadFile('dist/index.html', { hash: '/settings' });
    }

    this.settingsWindow.on('closed', () => {
      this.settingsWindow = null;
    });
  }

  // Event emitter pattern for communication
  private listeners: Map<string, Function[]> = new Map();
  
  on(event: string, callback: Function) {
    if (!this.listeners.has(event)) {
      this.listeners.set(event, []);
    }
    this.listeners.get(event)!.push(callback);
  }

  private emit(event: string, ...args: any[]) {
    this.listeners.get(event)?.forEach(cb => cb(...args));
  }
}
```

### 8. Settings Store (`electron/store.ts`)

**Requirements**:
- Persist user settings (API key, hotkey config, preferences)
- Secure storage for API key
- Default values for all settings

```typescript
import Store from 'electron-store';
import { safeStorage } from 'electron';

interface Settings {
  // API
  openaiApiKey: string; // Encrypted
  
  // Hotkey
  hotkeyType: 'double-tap' | 'single-key' | 'combo';
  hotkeyKey: string;
  hotkeyModifiers: string[];
  doubleTapThreshold: number;
  
  // Recording
  silenceDuration: number;
  silenceThreshold: number;
  
  // Processing
  whisperModel: 'whisper-1' | 'gpt-4o-transcribe' | 'gpt-4o-mini-transcribe';
  language: string;
  aiCleanupEnabled: boolean;
  
  // Insertion
  insertionMethod: 'paste' | 'type';
  restoreClipboard: boolean;
  typeDelay: number;
  
  // UI
  showTranscriptPreview: boolean;
}

const defaults: Settings = {
  openaiApiKey: '',
  hotkeyType: 'double-tap',
  hotkeyKey: 'Control',
  hotkeyModifiers: [],
  doubleTapThreshold: 300,
  silenceDuration: 900,
  silenceThreshold: 0.01,
  whisperModel: 'whisper-1',
  language: '',
  aiCleanupEnabled: false,
  insertionMethod: 'paste',
  restoreClipboard: true,
  typeDelay: 5,
  showTranscriptPreview: true,
};

class SettingsStore {
  private store: Store<Settings>;

  constructor() {
    this.store = new Store<Settings>({
      defaults,
      encryptionKey: 'spiel-v1', // Basic encryption
    });
  }

  get<K extends keyof Settings>(key: K): Settings[K] {
    const value = this.store.get(key);
    
    // Decrypt API key
    if (key === 'openaiApiKey' && value) {
      try {
        const decrypted = safeStorage.decryptString(Buffer.from(value as string, 'base64'));
        return decrypted as Settings[K];
      } catch {
        return '' as Settings[K];
      }
    }
    
    return value;
  }

  set<K extends keyof Settings>(key: K, value: Settings[K]): void {
    // Encrypt API key
    if (key === 'openaiApiKey' && value) {
      const encrypted = safeStorage.encryptString(value as string).toString('base64');
      this.store.set(key, encrypted as Settings[K]);
      return;
    }
    
    this.store.set(key, value);
  }

  getAll(): Settings {
    const all = this.store.store;
    return {
      ...all,
      openaiApiKey: this.get('openaiApiKey'),
    };
  }
}
```

## UI Components

### Recording Bar (`src/windows/RecordingBar.tsx`)

Small floating bar showing:
- Status indicator (idle/recording/processing)
- Audio waveform (when recording)
- Live transcript text (typewriter effect)
- Minimal controls

```tsx
import React, { useEffect, useState } from 'react';
import { Waveform } from '../components/Waveform';
import { TranscriptDisplay } from '../components/TranscriptDisplay';
import { StatusIndicator } from '../components/StatusIndicator';

type RecordingState = 'idle' | 'recording' | 'processing';

export function RecordingBar() {
  const [state, setState] = useState<RecordingState>('idle');
  const [transcript, setTranscript] = useState('');
  const [waveformData, setWaveformData] = useState<number[]>([]);

  useEffect(() => {
    // Listen for state changes from main process
    window.electronAPI.onRecordingStateChange((newState: RecordingState) => {
      setState(newState);
    });

    window.electronAPI.onTranscriptUpdate((text: string) => {
      setTranscript(prev => prev + text);
    });

    window.electronAPI.onWaveformData((data: number[]) => {
      setWaveformData(data);
    });

    window.electronAPI.onRecordingStop(() => {
      setTranscript('');
    });
  }, []);

  return (
    <div className="recording-bar bg-gray-900/90 backdrop-blur rounded-2xl p-4 flex items-center gap-4 shadow-2xl border border-gray-700">
      {/* Drag handle */}
      <div className="drag-handle cursor-move" style={{ WebkitAppRegion: 'drag' }}>
        <div className="w-1 h-8 bg-gray-600 rounded-full" />
      </div>

      {/* Status */}
      <StatusIndicator state={state} />

      {/* Content area */}
      <div className="flex-1 min-w-0">
        {state === 'recording' && (
          <Waveform data={waveformData} />
        )}
        
        {state === 'processing' && (
          <div className="text-gray-400 text-sm">Processing...</div>
        )}
        
        {transcript && (
          <TranscriptDisplay text={transcript} />
        )}
      </div>
    </div>
  );
}
```

### Settings Window (`src/windows/Settings.tsx`)

Full settings interface with sections:
- API Key configuration
- Hotkey settings
- Recording preferences
- AI cleanup toggle
- Insertion method

## IPC Channels

Define all IPC communication between main and renderer:

```typescript
// electron/ipc.ts
export const IPC_CHANNELS = {
  // Main -> Renderer
  RECORDING_STATE_CHANGE: 'recording:state-change',
  TRANSCRIPT_UPDATE: 'recording:transcript-update',
  WAVEFORM_DATA: 'recording:waveform-data',
  RECORDING_STOP: 'recording:stop',
  
  // Renderer -> Main
  TOGGLE_RECORDING: 'recording:toggle',
  GET_SETTINGS: 'settings:get',
  SET_SETTING: 'settings:set',
  TEST_API_KEY: 'settings:test-api-key',
  
  // Audio
  AUDIO_CHUNK: 'audio:chunk',
} as const;
```

## Build Configuration

### package.json

```json
{
  "name": "spiel",
  "version": "1.0.0",
  "description": "Voice-to-text dictation app for macOS using OpenAI Whisper",
  "main": "dist-electron/main.js",
  "scripts": {
    "dev": "vite",
    "build": "tsc && vite build && electron-builder",
    "build:mac": "tsc && vite build && electron-builder --mac",
    "electron:dev": "concurrently \"vite\" \"wait-on tcp:5173 && electron .\"",
    "typecheck": "tsc --noEmit"
  },
  "dependencies": {
    "electron-store": "^8.1.0",
    "openai": "^4.0.0",
    "robotjs": "^0.6.0",
    "uiohook-napi": "^1.5.0"
  },
  "devDependencies": {
    "@types/react": "^18.2.0",
    "@vitejs/plugin-react": "^4.0.0",
    "autoprefixer": "^10.4.0",
    "concurrently": "^8.0.0",
    "electron": "^36.0.0",
    "electron-builder": "^24.0.0",
    "postcss": "^8.4.0",
    "react": "^18.2.0",
    "react-dom": "^18.2.0",
    "tailwindcss": "^3.4.0",
    "typescript": "^5.0.0",
    "vite": "^5.0.0",
    "vite-plugin-electron": "^0.15.0",
    "wait-on": "^7.0.0",
    "zustand": "^4.4.0"
  }
}
```

### electron-builder.json

```json
{
  "appId": "com.spiel.app",
  "productName": "Spiel",
  "directories": {
    "output": "release"
  },
  "files": [
    "dist/**/*",
    "dist-electron/**/*",
    "resources/**/*"
  ],
  "mac": {
    "category": "public.app-category.productivity",
    "icon": "resources/icon.icns",
    "hardenedRuntime": true,
    "entitlements": "build/entitlements.mac.plist",
    "entitlementsInherit": "build/entitlements.mac.plist",
    "extendInfo": {
      "NSMicrophoneUsageDescription": "Spiel needs microphone access to record your voice for transcription.",
      "NSAppleEventsUsageDescription": "Spiel needs accessibility access to insert text into other applications."
    }
  },
  "dmg": {
    "contents": [
      { "x": 130, "y": 220 },
      { "x": 410, "y": 220, "type": "link", "path": "/Applications" }
    ]
  }
}
```

### macOS Entitlements (build/entitlements.mac.plist)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
```

## Testing Checklist

- [ ] Double-tap Control triggers recording
- [ ] F5 triggers recording (when macOS dictation disabled)
- [ ] Audio recording captures microphone
- [ ] Waveform displays during recording
- [ ] VAD detects pauses and sends chunks
- [ ] Whisper API returns transcriptions
- [ ] Transcriptions appear in floating bar
- [ ] AI cleanup improves text (when enabled)
- [ ] Text is pasted into target application
- [ ] Settings persist across app restarts
- [ ] Tray icon updates during recording
- [ ] App runs at login (optional)

## Future Enhancements (v2+)

- Local Whisper processing (whisper.cpp)
- Transcription history with search
- Per-app tone adjustment
- Custom vocabulary/corrections
- Keyboard shortcuts for quick commands
- Multiple language support
- Audio file import/export
