import { useEffect } from 'react'
import { useAppStore } from '../stores/appStore'

export function useRecordingState() {
  const {
    recordingState,
    setRecordingState,
    setError,
    setWaveformData,
  } = useAppStore()

  useEffect(() => {
    // Subscribe to recording state changes from main process
    const unsubscribeState = window.electronAPI.onRecordingStateChange((payload) => {
      setRecordingState(payload.state)
      if (payload.error) {
        setError(payload.error)
      }
    })

    // Subscribe to waveform data updates
    const unsubscribeWaveform = window.electronAPI.onWaveformData((payload) => {
      setWaveformData(payload.data)
    })

    return () => {
      unsubscribeState()
      unsubscribeWaveform()
    }
  }, [setRecordingState, setError, setWaveformData])

  const toggleRecording = async () => {
    await window.electronAPI.toggleRecording()
  }

  return {
    recordingState,
    toggleRecording,
  }
}
