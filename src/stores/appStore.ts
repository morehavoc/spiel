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
    set((state) => {
      // If appending just a newline, add it directly without space
      if (text === '\n') {
        // Remove any trailing whitespace/newline before adding the new one
        const trimmed = state.transcript.trimEnd()
        return { transcript: trimmed + '\n' }
      }
      // Strip trailing newline from incoming text (API adds them)
      const cleanText = text.replace(/\n+$/, '')
      // Add space between chunks if there's existing text that doesn't end with newline
      const needsSpace = state.transcript && !state.transcript.endsWith('\n')
      return {
        transcript: state.transcript + (needsSpace ? ' ' : '') + cleanText,
      }
    }),

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
