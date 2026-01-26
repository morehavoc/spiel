import { clipboard } from 'electron'
import { exec } from 'child_process'
import { promisify } from 'util'
import { getSetting } from '../store'

const execAsync = promisify(exec)

// Note: robotjs requires native compilation and may not work in all environments
// We'll use AppleScript as a fallback for macOS
let robotjs: typeof import('robotjs') | null = null

try {
  robotjs = require('robotjs')
} catch {
  console.warn('robotjs not available, falling back to AppleScript for keyboard simulation')
}

// Store the previous clipboard content
let savedClipboardText: string | null = null
let savedClipboardFormats: string[] = []

function saveClipboard(): void {
  savedClipboardFormats = clipboard.availableFormats()
  savedClipboardText = clipboard.readText()
}

function restoreClipboard(): void {
  if (savedClipboardText !== null) {
    // Small delay before restoring to ensure paste completes
    setTimeout(() => {
      clipboard.writeText(savedClipboardText || '')
      savedClipboardText = null
      savedClipboardFormats = []
    }, 100)
  }
}

async function simulatePaste(): Promise<void> {
  if (process.platform === 'darwin') {
    // Use AppleScript for more reliable key simulation on macOS
    await execAsync(`osascript -e 'tell application "System Events" to keystroke "v" using command down'`)
  } else if (robotjs) {
    // Use robotjs for other platforms
    robotjs.keyTap('v', ['command'])
  } else {
    throw new Error('No keyboard simulation method available')
  }
}

async function simulateTyping(text: string): Promise<void> {
  if (robotjs) {
    // Type character by character (slower but works in more apps)
    robotjs.typeString(text)
  } else if (process.platform === 'darwin') {
    // Use AppleScript for macOS
    // Escape special characters for AppleScript
    const escapedText = text
      .replace(/\\/g, '\\\\')
      .replace(/"/g, '\\"')
      .replace(/\n/g, '\\n')
    await execAsync(`osascript -e 'tell application "System Events" to keystroke "${escapedText}"'`)
  } else {
    throw new Error('No typing simulation method available')
  }
}

async function focusPreviousApp(): Promise<void> {
  if (process.platform === 'darwin') {
    // Activate the previously active application
    // This uses AppleScript to switch back to the previous app
    await execAsync(`osascript -e '
      tell application "System Events"
        set frontmostProcess to first process whose frontmost is true
        set visible of frontmostProcess to false
      end tell
    '`).catch(() => {
      // Silently fail - the app might already be in the background
    })

    // Small delay to ensure focus switch completes
    await new Promise((resolve) => setTimeout(resolve, 50))
  }
}

export async function insertText(text: string): Promise<{ success: boolean; error?: string }> {
  if (!text || text.trim().length === 0) {
    return { success: false, error: 'No text to insert' }
  }

  const insertionMethod = getSetting('insertionMethod')

  try {
    if (insertionMethod === 'paste') {
      // Save current clipboard
      saveClipboard()

      // Write text to clipboard
      clipboard.writeText(text)

      // Small delay to ensure clipboard is ready
      await new Promise((resolve) => setTimeout(resolve, 50))

      // Simulate Cmd+V
      await simulatePaste()

      // Restore clipboard after a delay
      restoreClipboard()

      return { success: true }
    } else {
      // Type character by character
      await simulateTyping(text)
      return { success: true }
    }
  } catch (error) {
    console.error('Text insertion error:', error)

    // If paste failed, at least the text is still in clipboard
    if (insertionMethod === 'paste') {
      return {
        success: false,
        error: 'Failed to paste text. The text is still in your clipboard - try pasting manually with Cmd+V.',
      }
    }

    return {
      success: false,
      error: error instanceof Error ? error.message : 'Failed to insert text',
    }
  }
}

// Alternative insertion that keeps text in clipboard without restoring
export async function insertTextKeepInClipboard(text: string): Promise<{ success: boolean; error?: string }> {
  if (!text || text.trim().length === 0) {
    return { success: false, error: 'No text to insert' }
  }

  try {
    clipboard.writeText(text)
    await new Promise((resolve) => setTimeout(resolve, 50))
    await simulatePaste()
    return { success: true }
  } catch (error) {
    return {
      success: false,
      error: 'Failed to paste text. The text is in your clipboard - try pasting manually.',
    }
  }
}
