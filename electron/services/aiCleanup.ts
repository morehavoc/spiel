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

export async function cleanupText(text: string): Promise<{ text: string; error?: string }> {
  // Check if AI cleanup is enabled
  const aiCleanupEnabled = getSetting('aiCleanupEnabled')
  if (!aiCleanupEnabled) {
    return { text }
  }

  try {
    const client = getClient()
    const systemPrompt = getSetting('aiCleanupPrompt')

    const completion = await client.chat.completions.create({
      model: 'gpt-4o-mini',
      messages: [
        { role: 'system', content: systemPrompt },
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
