import { useEffect, useCallback } from 'react'
import { StatusIndicator } from '../components/StatusIndicator'
import { Waveform } from '../components/Waveform'
import { TranscriptDisplay } from '../components/TranscriptDisplay'
import { useAppStore } from '../stores/appStore'
import { useAudioRecorder } from '../hooks/useAudioRecorder'
import { useTranscription } from '../hooks/useTranscription'

export function RecordingBar() {
  const {
    recordingState,
    setRecordingState,
    waveformData,
    setWaveformData,
    transcript,
    settings,
    setSettings,
    setError,
  } = useAppStore()

  const {
    isRecording,
    waveformData: localWaveformData,
    startRecording,
    stopRecording,
    onSpeechSegment,
  } = useAudioRecorder({
    silenceDuration: settings?.silenceDuration ?? 900,
    minSpeechDuration: settings?.minSpeechDuration ?? 500,
  })

  const { processAudioChunk, insertTranscript, clearTranscript } = useTranscription()

  // Load settings on mount
  useEffect(() => {
    window.electronAPI.getAllSettings().then(setSettings)
  }, [setSettings])

  // Update waveform data from local recorder
  useEffect(() => {
    setWaveformData(localWaveformData)
  }, [localWaveformData, setWaveformData])

  // Handle speech segments
  useEffect(() => {
    onSpeechSegment((blob) => {
      processAudioChunk(blob)
    })
  }, [onSpeechSegment, processAudioChunk])

  // Handle toggle recording from main process
  useEffect(() => {
    const unsubscribe = window.electronAPI.onToggleRecording(() => {
      handleToggleRecording()
    })
    return () => unsubscribe()
  }, [isRecording])

  const handleToggleRecording = useCallback(async () => {
    if (isRecording) {
      // Stop recording
      stopRecording()
      setRecordingState('idle')

      // Insert the transcript
      if (transcript.trim()) {
        await insertTranscript()
      }

      // Hide the recording bar
      await window.electronAPI.hideRecordingBar()
    } else {
      // Start recording
      try {
        await startRecording()
        setRecordingState('recording')
        clearTranscript()
      } catch (error) {
        setError(error instanceof Error ? error.message : 'Failed to start recording')
        setRecordingState('error')
      }
    }
  }, [isRecording, transcript, stopRecording, startRecording, setRecordingState, insertTranscript, clearTranscript, setError])

  // Start recording automatically when the window is shown
  useEffect(() => {
    const startOnShow = async () => {
      if (recordingState === 'idle') {
        try {
          await startRecording()
          setRecordingState('recording')
          clearTranscript()
        } catch (error) {
          setError(error instanceof Error ? error.message : 'Failed to start recording')
          setRecordingState('error')
        }
      }
    }

    // Small delay to ensure window is fully visible
    const timer = setTimeout(startOnShow, 100)
    return () => clearTimeout(timer)
  }, [])

  return (
    <div className="recording-bar bg-gray-900/95 backdrop-blur-sm rounded-2xl border border-gray-700 p-4 shadow-2xl">
      <div className="flex flex-col gap-3">
        {/* Header with status */}
        <div className="flex items-center justify-between">
          <StatusIndicator state={recordingState} />
          <button
            onClick={handleToggleRecording}
            className="px-3 py-1 text-xs font-medium text-gray-300 hover:text-white bg-gray-800 hover:bg-gray-700 rounded-lg transition-colors"
          >
            {isRecording ? 'Stop' : 'Start'}
          </button>
        </div>

        {/* Waveform */}
        <Waveform data={waveformData} isActive={isRecording} />

        {/* Transcript */}
        <TranscriptDisplay
          text={transcript}
          isProcessing={recordingState === 'processing'}
        />
      </div>
    </div>
  )
}
