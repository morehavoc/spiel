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

// Store the previous app's name to restore focus later
let previousAppName: string | null = null

export async function savePreviousApp(): Promise<void> {
  if (process.platform === 'darwin') {
    try {
      const { stdout } = await execAsync(`osascript -e '
        tell application "System Events"
          set frontApp to name of first process whose frontmost is true
          return frontApp
        end tell
      '`)
      previousAppName = stdout.trim()
      console.log('TextInserter: Saved previous app:', previousAppName)
    } catch (error) {
      console.error('TextInserter: Failed to save previous app:', error)
    }
  }
}

async function focusPreviousApp(): Promise<void> {
  if (process.platform === 'darwin' && previousAppName) {
    try {
      console.log('TextInserter: Activating previous app:', previousAppName)
      await execAsync(`osascript -e 'tell application "${previousAppName}" to activate'`)
      // Small delay to ensure focus switch completes
      await new Promise((resolve) => setTimeout(resolve, 100))
    } catch (error) {
      console.error('TextInserter: Failed to focus previous app:', error)
    }
  }
}

export async function insertText(text: string): Promise<{ success: boolean; error?: string }> {
  console.log('TextInserter: insertText called with', text.length, 'characters')

  if (!text || text.trim().length === 0) {
    return { success: false, error: 'No text to insert' }
  }

  const insertionMethod = getSetting('insertionMethod')
  console.log('TextInserter: Using insertion method:', insertionMethod)

  try {
    // Focus the previous app first
    console.log('TextInserter: Focusing previous app...')
    await focusPreviousApp()

    if (insertionMethod === 'paste') {
      // Save current clipboard
      saveClipboard()

      // Write text to clipboard
      clipboard.writeText(text)
      console.log('TextInserter: Wrote to clipboard:', text.substring(0, 50))
      console.log('TextInserter: Clipboard now contains:', clipboard.readText().substring(0, 50))

      // Small delay to ensure clipboard is ready and focus has switched
      await new Promise((resolve) => setTimeout(resolve, 100))

      // Simulate Cmd+V
      console.log('TextInserter: Simulating paste...')
      await simulatePaste()
      console.log('TextInserter: Paste simulated successfully')

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
