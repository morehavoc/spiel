import { create } from 'zustand'
import type { RecordingState, AppSettings } from '../types/electron.d'

interface AppStoreState {
  // Recording state
  recordingState: RecordingState
  transcript: string
  waveformData: number[]
  error: string | null

  // Settings (cached from main process)
  settings: AppSettings | null

  // Actions
  setRecordingState: (state: RecordingState) => void
  setTranscript: (text: string) => void
  appendTranscript: (text: string) => void
  clearTranscript: () => void
  setWaveformData: (data: number[]) => void
  setError: (error: string | null) => void
  setSettings: (settings: AppSettings) => void
  updateSetting: <K extends keyof AppSettings>(key: K, value: AppSettings[K]) => void
}

export const useAppStore = create<AppStoreState>((set) => ({
  // Initial state
  recordingState: 'idle',
  transcript: '',
  waveformData: new Array(32).fill(0),
  error: null,
  settings: null,

  // Actions
  setRecordingState: (state) => set({ recordingState: state }),

  setTranscript: (text) => set({ transcript: text }),

  appendTranscript: (text) =>
    set((state) => ({
      transcript: state.transcript + (state.transcript ? ' ' : '') + text,
    })),

  clearTranscript: () => set({ transcript: '' }),

  setWaveformData: (data) => set({ waveformData: data }),

  setError: (error) => set({ error }),

  setSettings: (settings) => set({ settings }),

  updateSetting: (key, value) =>
    set((state) => ({
      settings: state.settings
        ? { ...state.settings, [key]: value }
        : null,
    })),
}))
