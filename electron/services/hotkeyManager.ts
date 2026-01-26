import { uIOhook, UiohookKey } from 'uiohook-napi'
import { globalShortcut, BrowserWindow } from 'electron'
import { EventEmitter } from 'events'
import { getSetting } from '../store'
import { IPC_CHANNELS } from '../ipc'

class HotkeyManager extends EventEmitter {
  private lastControlPress = 0
  private lastF5Press = 0
  private isListening = false
  private recordingBarWindow: BrowserWindow | null = null

  constructor() {
    super()
  }

  setRecordingBarWindow(window: BrowserWindow | null): void {
    this.recordingBarWindow = window
  }

  start(): void {
    if (this.isListening) return

    const hotkeyMode = getSetting('hotkeyMode')

    if (hotkeyMode === 'custom') {
      this.setupCustomHotkey()
    } else {
      this.setupUiohook()
    }

    this.isListening = true
  }

  stop(): void {
    if (!this.isListening) return

    uIOhook.stop()
    globalShortcut.unregisterAll()
    this.isListening = false
  }

  private setupUiohook(): void {
    uIOhook.on('keydown', (event) => {
      const hotkeyMode = getSetting('hotkeyMode')
      const threshold = getSetting('doubleTapThreshold')
      const now = Date.now()

      if (hotkeyMode === 'double-tap-control') {
        // Check for Control key (left or right)
        if (event.keycode === UiohookKey.Ctrl || event.keycode === UiohookKey.CtrlRight) {
          if (now - this.lastControlPress < threshold) {
            this.triggerRecording()
            this.lastControlPress = 0 // Reset to prevent triple-tap
          } else {
            this.lastControlPress = now
          }
        }
      } else if (hotkeyMode === 'f5') {
        if (event.keycode === UiohookKey.F5) {
          if (now - this.lastF5Press < threshold) {
            this.triggerRecording()
            this.lastF5Press = 0
          } else {
            this.lastF5Press = now
          }
        }
      }
    })

    try {
      uIOhook.start()
    } catch (error) {
      console.error('Failed to start uiohook:', error)
      // This typically means accessibility permissions are not granted
      this.emit('accessibility-error', error)
    }
  }

  private setupCustomHotkey(): void {
    const customHotkey = getSetting('customHotkey')

    try {
      const registered = globalShortcut.register(customHotkey, () => {
        this.triggerRecording()
      })

      if (!registered) {
        console.error('Failed to register custom hotkey:', customHotkey)
        this.emit('hotkey-error', new Error(`Failed to register hotkey: ${customHotkey}`))
      }
    } catch (error) {
      console.error('Error registering custom hotkey:', error)
      this.emit('hotkey-error', error)
    }
  }

  private triggerRecording(): void {
    this.emit('trigger')

    // Send toggle recording event to the recording bar window
    if (this.recordingBarWindow && !this.recordingBarWindow.isDestroyed()) {
      this.recordingBarWindow.webContents.send(IPC_CHANNELS.RECORDING_TOGGLE)
    }
  }

  // Call this when settings change to update the hotkey configuration
  reloadSettings(): void {
    this.stop()
    this.start()
  }
}

// Singleton instance
export const hotkeyManager = new HotkeyManager()
