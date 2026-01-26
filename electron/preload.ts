import { contextBridge, ipcRenderer } from 'electron'
import { IPC_CHANNELS, RecordingStatePayload, TranscriptUpdatePayload, WaveformDataPayload } from './ipc'

// Type-safe event listener management
type UnsubscribeFn = () => void

const electronAPI = {
  // Recording control
  toggleRecording: () => ipcRenderer.invoke(IPC_CHANNELS.RECORDING_TOGGLE),

  onRecordingStateChange: (callback: (payload: RecordingStatePayload) => void): UnsubscribeFn => {
    const handler = (_event: Electron.IpcRendererEvent, payload: RecordingStatePayload) => callback(payload)
    ipcRenderer.on(IPC_CHANNELS.RECORDING_STATE_CHANGE, handler)
    return () => ipcRenderer.removeListener(IPC_CHANNELS.RECORDING_STATE_CHANGE, handler)
  },

  onTranscriptUpdate: (callback: (payload: TranscriptUpdatePayload) => void): UnsubscribeFn => {
    const handler = (_event: Electron.IpcRendererEvent, payload: TranscriptUpdatePayload) => callback(payload)
    ipcRenderer.on(IPC_CHANNELS.RECORDING_TRANSCRIPT_UPDATE, handler)
    return () => ipcRenderer.removeListener(IPC_CHANNELS.RECORDING_TRANSCRIPT_UPDATE, handler)
  },

  onWaveformData: (callback: (payload: WaveformDataPayload) => void): UnsubscribeFn => {
    const handler = (_event: Electron.IpcRendererEvent, payload: WaveformDataPayload) => callback(payload)
    ipcRenderer.on(IPC_CHANNELS.RECORDING_WAVEFORM_DATA, handler)
    return () => ipcRenderer.removeListener(IPC_CHANNELS.RECORDING_WAVEFORM_DATA, handler)
  },

  // Audio - send audio chunks from renderer to main
  sendAudioChunk: (buffer: ArrayBuffer, timestamp: number) =>
    ipcRenderer.invoke(IPC_CHANNELS.AUDIO_CHUNK, { buffer, timestamp }),

  // Settings
  getSetting: <T>(key: string): Promise<T> => ipcRenderer.invoke(IPC_CHANNELS.SETTINGS_GET, key),
  setSetting: <T>(key: string, value: T): Promise<void> =>
    ipcRenderer.invoke(IPC_CHANNELS.SETTINGS_SET, { key, value }),
  getAllSettings: () => ipcRenderer.invoke(IPC_CHANNELS.SETTINGS_GET_ALL),

  // API
  testApiKey: (key: string): Promise<{ valid: boolean; error?: string }> =>
    ipcRenderer.invoke(IPC_CHANNELS.API_TEST_KEY, key),
  transcribe: (audioBuffer: ArrayBuffer): Promise<{ text: string; error?: string }> =>
    ipcRenderer.invoke(IPC_CHANNELS.API_TRANSCRIBE, audioBuffer),
  cleanupText: (text: string): Promise<{ text: string; error?: string }> =>
    ipcRenderer.invoke(IPC_CHANNELS.API_CLEANUP, text),

  // Window
  showSettings: () => ipcRenderer.invoke(IPC_CHANNELS.WINDOW_SHOW_SETTINGS),
  showRecordingBar: () => ipcRenderer.invoke(IPC_CHANNELS.WINDOW_SHOW_RECORDING_BAR),
  hideRecordingBar: () => ipcRenderer.invoke(IPC_CHANNELS.WINDOW_HIDE_RECORDING_BAR),

  // System
  getPermissions: (): Promise<{ microphone: boolean; accessibility: boolean }> =>
    ipcRenderer.invoke(IPC_CHANNELS.SYSTEM_GET_PERMISSIONS),
  requestMicrophonePermission: (): Promise<boolean> =>
    ipcRenderer.invoke(IPC_CHANNELS.SYSTEM_REQUEST_MIC_PERMISSION),

  // Text insertion
  insertText: (text: string): Promise<{ success: boolean; error?: string }> =>
    ipcRenderer.invoke(IPC_CHANNELS.TEXT_INSERT, text),

  // Listen for toggle recording from tray/hotkey
  onToggleRecording: (callback: () => void): UnsubscribeFn => {
    const handler = () => callback()
    ipcRenderer.on(IPC_CHANNELS.RECORDING_TOGGLE, handler)
    return () => ipcRenderer.removeListener(IPC_CHANNELS.RECORDING_TOGGLE, handler)
  },
}

contextBridge.exposeInMainWorld('electronAPI', electronAPI)

export type ElectronAPI = typeof electronAPI
