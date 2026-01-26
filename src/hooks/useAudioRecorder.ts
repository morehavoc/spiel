import { useState, useRef, useCallback, useEffect } from 'react'
import { VADProcessor } from '../services/vadProcessor'

export interface UseAudioRecorderConfig {
  silenceDuration?: number
  minSpeechDuration?: number
  silenceThreshold?: number
}

export interface UseAudioRecorderReturn {
  isRecording: boolean
  waveformData: number[]
  error: string | null
  startRecording: () => Promise<void>
  stopRecording: () => void
  onSpeechSegment: (callback: (blob: Blob) => void) => void
}

export function useAudioRecorder(config: UseAudioRecorderConfig = {}): UseAudioRecorderReturn {
  const [isRecording, setIsRecording] = useState(false)
  const [waveformData, setWaveformData] = useState<number[]>(new Array(32).fill(0))
  const [error, setError] = useState<string | null>(null)

  const mediaRecorderRef = useRef<MediaRecorder | null>(null)
  const audioContextRef = useRef<AudioContext | null>(null)
  const analyserRef = useRef<AnalyserNode | null>(null)
  const sourceRef = useRef<MediaStreamAudioSourceNode | null>(null)
  const streamRef = useRef<MediaStream | null>(null)
  const vadRef = useRef<VADProcessor | null>(null)
  const speechCallbackRef = useRef<((blob: Blob) => void) | null>(null)

  const onSpeechSegment = useCallback((callback: (blob: Blob) => void) => {
    speechCallbackRef.current = callback
  }, [])

  const startRecording = useCallback(async () => {
    try {
      setError(null)

      // Request microphone access
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          sampleRate: 16000,
          channelCount: 1,
          echoCancellation: true,
          noiseSuppression: true,
        },
      })
      streamRef.current = stream

      // Create audio context for analysis
      const audioContext = new AudioContext({ sampleRate: 16000 })
      audioContextRef.current = audioContext

      // Create analyser node
      const analyser = audioContext.createAnalyser()
      analyser.fftSize = 2048
      analyserRef.current = analyser

      // Connect microphone to analyser
      const source = audioContext.createMediaStreamSource(stream)
      source.connect(analyser)
      sourceRef.current = source

      // Create VAD processor
      const vad = new VADProcessor(
        {
          silenceDuration: config.silenceDuration ?? 900,
          minSpeechDuration: config.minSpeechDuration ?? 500,
          silenceThreshold: config.silenceThreshold ?? 0.01,
          sampleRate: 16000,
        },
        {
          onSpeechStart: () => {
            console.log('Speech started')
          },
          onSpeechEnd: (blob) => {
            console.log('Speech ended, blob size:', blob.size)
            if (speechCallbackRef.current) {
              speechCallbackRef.current(blob)
            }
          },
          onWaveformData: (data) => {
            setWaveformData(data)
          },
        }
      )
      vadRef.current = vad
      vad.setAnalyserNode(analyser)

      // Create MediaRecorder
      const mimeType = MediaRecorder.isTypeSupported('audio/webm;codecs=opus')
        ? 'audio/webm;codecs=opus'
        : 'audio/webm'

      const mediaRecorder = new MediaRecorder(stream, {
        mimeType,
        audioBitsPerSecond: 16000,
      })
      mediaRecorderRef.current = mediaRecorder

      // Handle data chunks
      mediaRecorder.ondataavailable = (event) => {
        if (event.data.size > 0 && vadRef.current) {
          vadRef.current.processAudioChunk(event.data)
        }
      }

      // Start recording with timeslice to get regular chunks
      mediaRecorder.start(100) // Get data every 100ms
      setIsRecording(true)
    } catch (err) {
      console.error('Failed to start recording:', err)
      setError(err instanceof Error ? err.message : 'Failed to start recording')
    }
  }, [config.silenceDuration, config.minSpeechDuration, config.silenceThreshold])

  const stopRecording = useCallback(() => {
    // Force complete any pending speech segment
    if (vadRef.current) {
      vadRef.current.forceComplete()
      vadRef.current.stop()
      vadRef.current = null
    }

    // Stop MediaRecorder
    if (mediaRecorderRef.current && mediaRecorderRef.current.state !== 'inactive') {
      mediaRecorderRef.current.stop()
    }
    mediaRecorderRef.current = null

    // Disconnect and close audio context
    if (sourceRef.current) {
      sourceRef.current.disconnect()
      sourceRef.current = null
    }
    if (analyserRef.current) {
      analyserRef.current = null
    }
    if (audioContextRef.current) {
      audioContextRef.current.close()
      audioContextRef.current = null
    }

    // Stop all tracks
    if (streamRef.current) {
      streamRef.current.getTracks().forEach((track) => track.stop())
      streamRef.current = null
    }

    setIsRecording(false)
    setWaveformData(new Array(32).fill(0))
  }, [])

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      stopRecording()
    }
  }, [stopRecording])

  return {
    isRecording,
    waveformData,
    error,
    startRecording,
    stopRecording,
    onSpeechSegment,
  }
}
