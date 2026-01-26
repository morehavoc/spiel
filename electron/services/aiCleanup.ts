import OpenAI from 'openai'
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

const CLEANUP_SYSTEM_PROMPT = `You are a text cleanup assistant. Your task is to clean up transcribed speech while preserving the original meaning and intent.

Rules:
1. Fix obvious grammar and punctuation errors
2. Remove filler words like "um", "uh", "like", "you know", etc.
3. Fix sentence structure if it's unclear
4. Keep the original tone and style
5. Don't add information that wasn't there
6. Don't change the meaning
7. If the text is already clean, return it as-is
8. Return ONLY the cleaned text, no explanations`

export async function cleanupText(text: string): Promise<{ text: string; error?: string }> {
  // Check if AI cleanup is enabled
  const aiCleanupEnabled = getSetting('aiCleanupEnabled')
  if (!aiCleanupEnabled) {
    return { text }
  }

  try {
    const client = getClient()

    const completion = await client.chat.completions.create({
      model: 'gpt-4o-mini',
      messages: [
        { role: 'system', content: CLEANUP_SYSTEM_PROMPT },
        { role: 'user', content: text },
      ],
      temperature: 0.3,
      max_tokens: 1000,
    })

    const cleanedText = completion.choices[0]?.message?.content?.trim()

    if (!cleanedText) {
      return { text }
    }

    return { text: cleanedText }
  } catch (error) {
    console.error('AI cleanup error:', error)

    if (error instanceof OpenAI.AuthenticationError) {
      return { text, error: 'Invalid API key' }
    }
    if (error instanceof OpenAI.RateLimitError) {
      // Return original text on rate limit but note the error
      return { text, error: 'Rate limit exceeded, using original text' }
    }

    // Return original text on any error
    return {
      text,
      error: error instanceof Error ? error.message : 'Cleanup failed, using original text',
    }
  }
}
