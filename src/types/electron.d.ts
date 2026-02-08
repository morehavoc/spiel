// Type definitions for the Electron API exposed via preload

export type RecordingState = 'idle' | 'recording' | 'processing' | 'error'

export interface RecordingStatePayload {
  state: RecordingState
  error?: string
}

export interface TranscriptUpdatePayload {
  text: string
  isFinal: boolean
}

export interface WaveformDataPayload {
  data: number[]
}

export interface AppSettings {
  apiKey: string
  hotkeyMode: 'cmd-backslash' | 'f5' | 'custom'
  customHotkey: string
  silenceDuration: number
  minSpeechDuration: number
  languageHint: string
  aiCleanupEnabled: boolean
  aiCleanupPrompt: string
  insertionMethod: 'paste' | 'type'
  launchAtLogin: boolean
  showInDock: boolean
  recordingBarPosition: { x: number; y: number } | null
}

type UnsubscribeFn = () => void

export interface ElectronAPI {
  // Recording control
  toggleRecording: () => Promise<void>
  onRecordingStateChange: (callback: (payload: RecordingStatePayload) => void) => UnsubscribeFn
  onTranscriptUpdate: (callback: (payload: TranscriptUpdatePayload) => void) => UnsubscribeFn
  onWaveformData: (callback: (payload: WaveformDataPayload) => void) => UnsubscribeFn

  // Audio
  sendAudioChunk: (buffer: ArrayBuffer, timestamp: number) => Promise<{ success: boolean }>

  // Settings
  getSetting: <T>(key: string) => Promise<T>
  setSetting: <T>(key: string, value: T) => Promise<void>
  getAllSettings: () => Promise<AppSettings>

  // API
  testApiKey: (key: string) => Promise<{ valid: boolean; error?: string }>
  transcribe: (audioBuffer: ArrayBuffer) => Promise<{ text: string; error?: string }>
  cleanupText: (text: string) => Promise<{ text: string; error?: string }>

  // Window
  showSettings: () => Promise<void>
  showRecordingBar: () => Promise<void>
  hideRecordingBar: () => Promise<void>
  stopRecordingAndInsert: (text: string) => Promise<{ success: boolean; error?: string }>

  // System
  getPermissions: () => Promise<{ microphone: boolean; accessibility: boolean }>
  requestMicrophonePermission: () => Promise<boolean>

  // Text insertion
  insertText: (text: string) => Promise<{ success: boolean; error?: string }>

  // Listen for toggle recording from tray/hotkey
  onToggleRecording: (callback: () => void) => UnsubscribeFn
}

declare global {
  interface Window {
    electronAPI: ElectronAPI
  }
}
