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
      console.log('useTranscription: Sending audio to main process, size:', arrayBuffer.byteLength)

      // Send to main process for transcription
      const result = await window.electronAPI.transcribe(arrayBuffer)
      console.log('useTranscription: Received result from main:', result)

      if (result.error) {
        console.error('useTranscription: Transcription error:', result.error)
        return
      }

      if (result.text) {
        console.log('useTranscription: Got text:', result.text)
        // Append raw transcription - AI cleanup happens at the end on full text
        appendTranscript(result.text)
      } else {
        console.log('useTranscription: No text in result')
      }
    } catch (error) {
      console.error('useTranscription: Error processing audio chunk:', error)
    } finally {
      setRecordingState('recording')
    }
  }, [appendTranscript, setRecordingState])

  const insertTranscript = useCallback(async () => {
    console.log('insertTranscript called, transcript:', transcript.substring(0, 50))
    if (!transcript.trim()) {
      console.log('insertTranscript: No transcript to insert')
      return
    }

    try {
      console.log('insertTranscript: Calling insertText IPC...')
      const result = await window.electronAPI.insertText(transcript)
      console.log('insertTranscript: Result:', result)
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
