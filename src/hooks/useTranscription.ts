import { useEffect, useCallback } from 'react'
import { useAppStore } from '../stores/appStore'

export function useTranscription() {
  const {
    transcript,
    setTranscript,
    appendTranscript,
    clearTranscript,
    setRecordingState,
  } = useAppStore()

  useEffect(() => {
    // Subscribe to transcript updates from main process
    const unsubscribe = window.electronAPI.onTranscriptUpdate((payload) => {
      if (payload.isFinal) {
        setTranscript(payload.text)
      } else {
        appendTranscript(payload.text)
      }
    })

    return () => {
      unsubscribe()
    }
  }, [setTranscript, appendTranscript])

  const processAudioChunk = useCallback(async (audioBlob: Blob) => {
    try {
      setRecordingState('processing')

      // Convert blob to ArrayBuffer
      const arrayBuffer = await audioBlob.arrayBuffer()

      // Send to main process for transcription
      const result = await window.electronAPI.transcribe(arrayBuffer)

      if (result.error) {
        console.error('Transcription error:', result.error)
        return
      }

      if (result.text) {
        // Optionally apply AI cleanup
        const cleanedResult = await window.electronAPI.cleanupText(result.text)
        const finalText = cleanedResult.text || result.text

        appendTranscript(finalText)
      }
    } catch (error) {
      console.error('Error processing audio chunk:', error)
    } finally {
      setRecordingState('recording')
    }
  }, [appendTranscript, setRecordingState])

  const insertTranscript = useCallback(async () => {
    if (!transcript.trim()) return

    try {
      const result = await window.electronAPI.insertText(transcript)
      if (result.success) {
        clearTranscript()
      } else if (result.error) {
        console.error('Insert error:', result.error)
      }
    } catch (error) {
      console.error('Error inserting text:', error)
    }
  }, [transcript, clearTranscript])

  return {
    transcript,
    processAudioChunk,
    insertTranscript,
    clearTranscript,
  }
}
