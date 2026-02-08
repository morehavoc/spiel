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

  // Track if we're waiting to stop (user requested stop while processing)
  const pendingStopRef = useRef(false)
  const processingCountRef = useRef(0)

  // Wrap processAudioChunk to track pending operations
  const processAudioChunkTracked = useCallback(async (blob: Blob) => {
    processingCountRef.current++
    try {
      await processAudioChunk(blob)
    } finally {
      processingCountRef.current--
      // If stop was requested and this was the last pending operation, complete the stop
      if (pendingStopRef.current && processingCountRef.current === 0) {
        pendingStopRef.current = false
        // Get the latest transcript from the store
        const finalTranscript = useAppStore.getState().transcript.trim()
        console.log('Processing complete, now stopping with transcript:', finalTranscript.substring(0, 50))
        const result = await window.electronAPI.stopRecordingAndInsert(finalTranscript)
        if (result.success) {
          clearTranscript()
        }
      }
    }
  }, [processAudioChunk, clearTranscript])

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
      processAudioChunkTracked(blob)
    })
  }, [onSpeechSegment, processAudioChunkTracked])

  const handleToggleRecording = useCallback(async () => {
    console.log('handleToggleRecording called, isRecording:', isRecording)
    if (isRecording) {
      console.log('Stopping recording, transcript length:', transcript.length, 'pending operations:', processingCountRef.current)
      // Stop the audio recorder immediately (no new audio captured)
      stopRecording()

      // Check if there are pending transcription operations
      if (processingCountRef.current > 0) {
        console.log('Waiting for pending transcriptions to complete...')
        setRecordingState('processing') // Show processing state
        pendingStopRef.current = true
        // The actual stop will happen when processing completes (see processAudioChunkTracked)
        return
      }

      // No pending operations, stop immediately
      setRecordingState('idle')
      const textToInsert = transcript.trim()
      console.log('Calling stopRecordingAndInsert with text:', textToInsert.substring(0, 50))
      const result = await window.electronAPI.stopRecordingAndInsert(textToInsert)
      console.log('stopRecordingAndInsert result:', result)

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

  // Handle keyboard shortcuts: Enter to stop/insert, Escape to cancel
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Enter' && isRecording) {
        e.preventDefault()
        console.log('Enter pressed, stopping and inserting')
        handleToggleRef.current()
      } else if (e.key === 'Escape' && isRecording) {
        e.preventDefault()
        console.log('Escape pressed, canceling')
        stopRecording()
        clearTranscript()
        setRecordingState('idle')
        window.electronAPI.hideRecordingBar()
      }
    }

    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [isRecording, stopRecording, clearTranscript, setRecordingState])

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
    <div className="recording-bar h-full overflow-hidden bg-gray-900/95 backdrop-blur-sm rounded-2xl border border-gray-700 p-4 shadow-2xl">
      <div className="h-full flex flex-col gap-3 min-h-0">
        {/* Header with status */}
        <div className="flex items-center justify-between">
          <StatusIndicator state={recordingState} />
          <div className="flex items-center gap-2">
            <button
              onClick={() => window.electronAPI.showSettings()}
              className="p-1 text-gray-400 hover:text-white transition-colors"
              title="Settings"
            >
              <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <circle cx="12" cy="12" r="3"></circle>
                <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"></path>
              </svg>
            </button>
            <button
              onClick={handleToggleRecording}
              className="px-3 py-1 text-xs font-medium text-gray-300 hover:text-white bg-gray-800 hover:bg-gray-700 rounded-lg transition-colors"
            >
              {isRecording ? 'Stop' : 'Start'}
            </button>
          </div>
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
