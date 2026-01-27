// IPC Channel Constants
// All IPC channels are defined here for type safety and consistency

export const IPC_CHANNELS = {
  // Recording control
  RECORDING_TOGGLE: 'recording:toggle',
  RECORDING_STATE_CHANGE: 'recording:state-change',
  RECORDING_TRANSCRIPT_UPDATE: 'recording:transcript-update',
  RECORDING_WAVEFORM_DATA: 'recording:waveform-data',

  // Audio
  AUDIO_CHUNK: 'audio:chunk',

  // Settings
  SETTINGS_GET: 'settings:get',
  SETTINGS_SET: 'settings:set',
  SETTINGS_GET_ALL: 'settings:get-all',

  // API
  API_TEST_KEY: 'api:test-key',
  API_TRANSCRIBE: 'api:transcribe',
  API_CLEANUP: 'api:cleanup',

  // Window
  WINDOW_SHOW_SETTINGS: 'window:show-settings',
  WINDOW_SHOW_RECORDING_BAR: 'window:show-recording-bar',
  WINDOW_HIDE_RECORDING_BAR: 'window:hide-recording-bar',

  // System
  SYSTEM_GET_PERMISSIONS: 'system:get-permissions',
  SYSTEM_REQUEST_MIC_PERMISSION: 'system:request-mic-permission',

  // Text insertion
  TEXT_INSERT: 'text:insert',
  TEXT_INSERT_RESULT: 'text:insert-result',

  // Stop recording and insert
  RECORDING_STOP_AND_INSERT: 'recording:stop-and-insert',
} as const

export type IpcChannel = typeof IPC_CHANNELS[keyof typeof IPC_CHANNELS]

// Recording state types
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

export interface AudioChunkPayload {
  buffer: ArrayBuffer
  timestamp: number
}
