import { useEffect, useCallback, useRef } from 'react'
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

  const { processAudioChunk, clearTranscript } = useTranscription()

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
      console.log('RecordingBar: Speech segment received, size:', blob.size)
      processAudioChunk(blob)
    })
  }, [onSpeechSegment, processAudioChunk])

  const handleToggleRecording = useCallback(async () => {
    console.log('handleToggleRecording called, isRecording:', isRecording)
    if (isRecording) {
      console.log('Stopping recording, transcript length:', transcript.length)
      // Stop recording
      stopRecording()
      setRecordingState('idle')

      // Use atomic stop-and-insert which handles hiding window and inserting in main process
      const textToInsert = transcript.trim()
      console.log('Calling stopRecordingAndInsert with text:', textToInsert.substring(0, 50))
      const result = await window.electronAPI.stopRecordingAndInsert(textToInsert)
      console.log('stopRecordingAndInsert result:', result)

      // Clear the transcript after successful insert
      if (result.success) {
        clearTranscript()
      }
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
  }, [isRecording, transcript, stopRecording, startRecording, setRecordingState, clearTranscript, setError])

  // Handle toggle recording from main process
  // Use a ref to always have the latest callback to avoid stale closures
  const handleToggleRef = useRef(handleToggleRecording)
  useEffect(() => {
    handleToggleRef.current = handleToggleRecording
  }, [handleToggleRecording])

  useEffect(() => {
    console.log('Setting up onToggleRecording listener')
    const unsubscribe = window.electronAPI.onToggleRecording(() => {
      console.log('onToggleRecording callback fired')
      handleToggleRef.current()
    })
    return () => {
      console.log('Cleaning up onToggleRecording listener')
      unsubscribe()
    }
  }, []) // Only set up once, use ref for latest callback

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
    <div className="recording-bar h-full bg-gray-900/95 backdrop-blur-sm rounded-2xl border border-gray-700 p-4 shadow-2xl">
      <div className="h-full flex flex-col gap-3">
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
