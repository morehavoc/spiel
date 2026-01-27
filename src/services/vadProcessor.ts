// Voice Activity Detection (VAD) Processor
// Uses amplitude-based silence detection to segment speech

export interface VADConfig {
  silenceDuration: number // ms of silence before chunk is complete (default: 900)
  minSpeechDuration: number // ms of minimum speech before accepting (default: 500)
  silenceThreshold: number // amplitude threshold for silence (0-1, default: 0.01)
  sampleRate: number // audio sample rate (default: 16000)
}

export interface VADEvents {
  onSpeechStart: () => void
  onSpeechEnd: (audioBlob: Blob) => void
  onWaveformData: (data: number[]) => void
}

const DEFAULT_CONFIG: VADConfig = {
  silenceDuration: 900,
  minSpeechDuration: 500,
  silenceThreshold: 0.01,
  sampleRate: 16000,
}

export class VADProcessor {
  private config: VADConfig
  private events: VADEvents
  private isSpeaking = false
  private silenceStartTime = 0
  private speechStartTime = 0
  private audioChunks: Blob[] = []
  private headerChunk: Blob | null = null // WebM header must be preserved
  private analyserNode: AnalyserNode | null = null
  private animationFrameId: number | null = null

  constructor(config: Partial<VADConfig>, events: VADEvents) {
    this.config = { ...DEFAULT_CONFIG, ...config }
    this.events = events
  }

  setAnalyserNode(analyser: AnalyserNode): void {
    this.analyserNode = analyser
    this.startWaveformUpdates()
  }

  // Call this with each audio chunk from the MediaRecorder
  processAudioChunk(chunk: Blob): void {
    // The first chunk contains the WebM header - save it separately
    if (this.headerChunk === null) {
      this.headerChunk = chunk
      console.log('VAD: Saved header chunk, size:', chunk.size, 'bytes')
    }
    this.audioChunks.push(chunk)
  }

  // Call this periodically to analyze audio levels
  analyzeAudioLevel(audioData: Uint8Array): void {
    const amplitude = this.calculateAmplitude(audioData)
    const now = Date.now()
    const isSilent = amplitude < this.config.silenceThreshold

    if (!this.isSpeaking && !isSilent) {
      // Speech started
      this.isSpeaking = true
      this.speechStartTime = now
      this.silenceStartTime = 0
      this.audioChunks = []
      this.events.onSpeechStart()
    } else if (this.isSpeaking) {
      if (isSilent) {
        if (this.silenceStartTime === 0) {
          this.silenceStartTime = now
        } else if (now - this.silenceStartTime >= this.config.silenceDuration) {
          // Silence duration exceeded - check if speech was long enough
          const speechDuration = this.silenceStartTime - this.speechStartTime
          if (speechDuration >= this.config.minSpeechDuration) {
            this.completeSpeechSegment()
          } else {
            // Speech too short, reset
            this.resetState()
          }
        }
      } else {
        // Still speaking, reset silence timer
        this.silenceStartTime = 0
      }
    }
  }

  private calculateAmplitude(audioData: Uint8Array): number {
    let sum = 0
    for (let i = 0; i < audioData.length; i++) {
      // Convert from 0-255 to -1 to 1
      const normalized = (audioData[i] - 128) / 128
      sum += Math.abs(normalized)
    }
    return sum / audioData.length
  }

  private completeSpeechSegment(): void {
    if (this.audioChunks.length > 0) {
      // Always include the header chunk at the beginning for a valid WebM file
      const hasHeader = this.headerChunk !== null
      const needsPrepend = hasHeader && this.audioChunks[0] !== this.headerChunk
      const chunks = needsPrepend
        ? [this.headerChunk!, ...this.audioChunks]
        : this.audioChunks

      console.log('VAD: Creating audio blob', {
        hasHeader,
        needsPrepend,
        headerSize: this.headerChunk?.size ?? 0,
        chunkCount: this.audioChunks.length,
        totalChunks: chunks.length,
      })

      const audioBlob = new Blob(chunks, { type: 'audio/webm;codecs=opus' })
      console.log('VAD: Final blob size:', audioBlob.size, 'bytes')
      this.events.onSpeechEnd(audioBlob)
    }
    this.resetState()
  }

  private resetState(): void {
    this.isSpeaking = false
    this.silenceStartTime = 0
    this.speechStartTime = 0
    this.audioChunks = []
    // Don't reset headerChunk - it stays valid for the entire recording session
  }

  private startWaveformUpdates(): void {
    if (!this.analyserNode) return

    const dataArray = new Uint8Array(this.analyserNode.frequencyBinCount)

    const update = () => {
      if (!this.analyserNode) return

      this.analyserNode.getByteTimeDomainData(dataArray)

      // Analyze audio level
      this.analyzeAudioLevel(dataArray)

      // Send waveform data for visualization
      // Downsample to 32 points for visualization
      const downsampledData: number[] = []
      const step = Math.floor(dataArray.length / 32)
      for (let i = 0; i < 32; i++) {
        const index = i * step
        // Normalize to 0-1 range
        downsampledData.push((dataArray[index] - 128) / 128)
      }
      this.events.onWaveformData(downsampledData)

      this.animationFrameId = requestAnimationFrame(update)
    }

    update()
  }

  // Force complete the current speech segment (e.g., when stopping recording)
  forceComplete(): void {
    if (this.isSpeaking && this.audioChunks.length > 0) {
      const speechDuration = Date.now() - this.speechStartTime
      if (speechDuration >= this.config.minSpeechDuration) {
        this.completeSpeechSegment()
      }
    }
    this.resetState()
  }

  stop(): void {
    if (this.animationFrameId !== null) {
      cancelAnimationFrame(this.animationFrameId)
      this.animationFrameId = null
    }
    this.analyserNode = null
  }

  updateConfig(config: Partial<VADConfig>): void {
    this.config = { ...this.config, ...config }
  }
}
