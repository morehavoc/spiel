import OpenAI from 'openai'
import { getApiKey, getSetting } from '../store'
import { Readable } from 'stream'

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

    // Convert ArrayBuffer to a file-like object for the API
    const audioBlob = new Blob([audioBuffer], { type: 'audio/webm' })

    // Create a File object from the blob
    const file = new File([audioBlob], 'audio.webm', { type: 'audio/webm' })

    const transcription = await client.audio.transcriptions.create({
      file: file,
      model: 'gpt-4o-mini-transcribe',
      language: languageHint || undefined,
      response_format: 'text',
    })

    return { text: transcription }
  } catch (error) {
    console.error('Transcription error:', error)

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

// Convert ArrayBuffer to a readable stream for the OpenAI API
function arrayBufferToReadable(buffer: ArrayBuffer): Readable {
  const readable = new Readable()
  readable.push(Buffer.from(buffer))
  readable.push(null)
  return readable
}
