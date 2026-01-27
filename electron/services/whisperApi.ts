import OpenAI, { toFile } from 'openai'
import { getApiKey, getSetting } from '../store'

let openaiClient: OpenAI | null = null

function getClient(): OpenAI {
  const apiKey = getApiKey()
  if (!apiKey) {
    throw new Error('API key not configured')
  }

  if (!openaiClient) {
    openaiClient = new OpenAI({ apiKey })
  }

  return openaiClient
}

// Reset client when API key changes
export function resetClient(): void {
  openaiClient = null
}

export async function testApiKey(apiKey: string): Promise<{ valid: boolean; error?: string }> {
  try {
    const testClient = new OpenAI({ apiKey })

    // Make a simple API call to verify the key works
    // Using models list as a lightweight check
    await testClient.models.list()

    return { valid: true }
  } catch (error) {
    if (error instanceof OpenAI.AuthenticationError) {
      return { valid: false, error: 'Invalid API key' }
    }
    if (error instanceof OpenAI.RateLimitError) {
      // Rate limited but key is valid
      return { valid: true }
    }
    return {
      valid: false,
      error: error instanceof Error ? error.message : 'Unknown error',
    }
  }
}

export async function transcribeAudio(
  audioBuffer: ArrayBuffer
): Promise<{ text: string; error?: string }> {
  try {
    const client = getClient()
    const languageHint = getSetting('languageHint')

    // Convert ArrayBuffer to Buffer (Node.js)
    const buffer = Buffer.from(audioBuffer)
    console.log('Whisper API: Received audio buffer, size:', buffer.length, 'bytes')

    // Use OpenAI's toFile helper to create a proper file object
    console.log('Whisper API: Creating file object...')
    const file = await toFile(buffer, 'audio.webm', { type: 'audio/webm' })
    console.log('Whisper API: File object created')

    console.log('Whisper API: Calling transcription API...')
    const transcription = await client.audio.transcriptions.create({
      file: file,
      model: 'gpt-4o-mini-transcribe',
      language: languageHint || undefined,
      response_format: 'text',
    })

    console.log('Whisper API: Transcription result:', transcription)
    return { text: transcription }
  } catch (error) {
    console.error('Whisper API: Transcription error:', error)

    if (error instanceof OpenAI.AuthenticationError) {
      return { text: '', error: 'Invalid API key' }
    }
    if (error instanceof OpenAI.RateLimitError) {
      return { text: '', error: 'Rate limit exceeded. Please try again later.' }
    }
    if (error instanceof OpenAI.BadRequestError) {
      return { text: '', error: 'Audio format not supported or audio too short' }
    }

    return {
      text: '',
      error: error instanceof Error ? error.message : 'Transcription failed',
    }
  }
}
