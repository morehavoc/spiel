import { globalShortcut } from 'electron'
import { EventEmitter } from 'events'
import { getSetting } from '../store'
import { IPC_CHANNELS } from '../ipc'
import { getRecordingBarWindow } from './windowManager'

class HotkeyManager extends EventEmitter {
  private isListening = false
  private currentShortcut: string | null = null

  constructor() {
    super()
  }

  start(): void {
    if (this.isListening) return

    const hotkeyMode = getSetting('hotkeyMode')
    let shortcut: string

    if (hotkeyMode === 'custom') {
      shortcut = getSetting('customHotkey')
    } else if (hotkeyMode === 'f5') {
      shortcut = 'F5'
    } else {
      // Default: cmd+backslash
      shortcut = 'CommandOrControl+\\'
    }

    this.registerShortcut(shortcut)
    this.isListening = true
  }

  stop(): void {
    if (!this.isListening) return

    globalShortcut.unregisterAll()
    this.currentShortcut = null
    this.isListening = false
  }

  private registerShortcut(shortcut: string): void {
    try {
      const registered = globalShortcut.register(shortcut, () => {
        this.triggerRecording()
      })

      if (!registered) {
        console.error('Failed to register hotkey:', shortcut)
        this.emit('hotkey-error', new Error(`Failed to register hotkey: ${shortcut}`))
      } else {
        this.currentShortcut = shortcut
        console.log('Registered hotkey:', shortcut)
      }
    } catch (error) {
      console.error('Error registering hotkey:', error)
      this.emit('hotkey-error', error)
    }
  }

  private triggerRecording(): void {
    console.log('HotkeyManager: Trigger fired')
    this.emit('trigger')

    // Send toggle recording event to the recording bar window
    const recordingBarWindow = getRecordingBarWindow()
    if (recordingBarWindow && !recordingBarWindow.isDestroyed()) {
      console.log('HotkeyManager: Sending toggle to recording bar window')
      recordingBarWindow.webContents.send(IPC_CHANNELS.RECORDING_TOGGLE)
    } else {
      console.log('HotkeyManager: No recording bar window to send toggle to')
    }
  }

  // Call this when settings change to update the hotkey configuration
  reloadSettings(): void {
    this.stop()
    this.start()
  }

  // Get the currently registered shortcut for display
  getCurrentShortcut(): string | null {
    return this.currentShortcut
  }
}

// Singleton instance
export const hotkeyManager = new HotkeyManager()
