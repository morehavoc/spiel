import { app, BrowserWindow, ipcMain, systemPreferences } from 'electron'
import path from 'path'
import { IPC_CHANNELS } from './ipc'

const isDev = process.env.VITE_DEV_SERVER_URL !== undefined

// Get the path to the preload script
function getPreloadPath(): string {
  if (isDev) {
    return path.join(process.cwd(), 'dist-electron', 'preload.js')
  }
  return path.join(app.getAppPath(), 'dist-electron', 'preload.js')
}
import { getSetting, setSetting, getAllSettings } from './store'
import {
  createTray,
  createRecordingBarWindow,
  showSettingsWindow,
  showRecordingBar,
  hideRecordingBar,
  destroyAllWindows,
  getRecordingBarWindow,
} from './services/windowManager'
import { hotkeyManager } from './services/hotkeyManager'
import { testApiKey, transcribeAudio, resetClient as resetWhisperClient } from './services/whisperApi'
import { cleanupText, resetClient as resetCleanupClient } from './services/aiCleanup'
import { insertText } from './services/textInserter'

let mainWindow: BrowserWindow | null = null

// Export to prevent unused variable warning and allow access from other modules
export const getMainWindow = () => mainWindow

const createWindow = () => {
  // In production, we don't show a main window - just the tray and recording bar
  // For development, we show a main window for debugging
  if (isDev) {
    mainWindow = new BrowserWindow({
      width: 800,
      height: 600,
      webPreferences: {
        preload: getPreloadPath(),
        contextIsolation: true,
        nodeIntegration: false,
      },
    })

    mainWindow.loadURL(process.env.VITE_DEV_SERVER_URL!)
    mainWindow.webContents.openDevTools()
  }
}

// Check microphone permission
async function checkMicrophonePermission(): Promise<boolean> {
  if (process.platform === 'darwin') {
    const status = systemPreferences.getMediaAccessStatus('microphone')
    if (status === 'granted') {
      return true
    }
    if (status === 'not-determined') {
      return await systemPreferences.askForMediaAccess('microphone')
    }
    return false
  }
  return true // Assume granted on other platforms
}

// Setup IPC handlers
function setupIpcHandlers() {
  // Settings handlers
  ipcMain.handle(IPC_CHANNELS.SETTINGS_GET, (_event, key: string) => {
    return getSetting(key as keyof ReturnType<typeof getAllSettings>)
  })

  ipcMain.handle(IPC_CHANNELS.SETTINGS_SET, (_event, { key, value }) => {
    setSetting(key as keyof ReturnType<typeof getAllSettings>, value)

    // Handle special settings that need immediate action
    if (key === 'launchAtLogin') {
      app.setLoginItemSettings({
        openAtLogin: value as boolean,
        openAsHidden: true,
      })
    }

    if (key === 'showInDock' && process.platform === 'darwin') {
      if (value) {
        app.dock?.show()
      } else {
        app.dock?.hide()
      }
    }

    // Reload hotkey settings if they changed
    if (key === 'hotkeyMode' || key === 'customHotkey' || key === 'doubleTapThreshold') {
      hotkeyManager.reloadSettings()
    }
  })

  ipcMain.handle(IPC_CHANNELS.SETTINGS_GET_ALL, () => {
    return getAllSettings()
  })

  // Window handlers
  ipcMain.handle(IPC_CHANNELS.WINDOW_SHOW_SETTINGS, () => {
    showSettingsWindow()
  })

  ipcMain.handle(IPC_CHANNELS.WINDOW_SHOW_RECORDING_BAR, () => {
    showRecordingBar()
  })

  ipcMain.handle(IPC_CHANNELS.WINDOW_HIDE_RECORDING_BAR, () => {
    hideRecordingBar()
  })

  // System permission handlers
  ipcMain.handle(IPC_CHANNELS.SYSTEM_GET_PERMISSIONS, async () => {
    const microphone = await checkMicrophonePermission()
    // Accessibility permission check would go here
    // For now, we'll assume it's available and let uiohook handle the error
    return { microphone, accessibility: true }
  })

  ipcMain.handle(IPC_CHANNELS.SYSTEM_REQUEST_MIC_PERMISSION, async () => {
    return await checkMicrophonePermission()
  })

  // Recording toggle handler (from renderer)
  ipcMain.handle(IPC_CHANNELS.RECORDING_TOGGLE, () => {
    const recordingBar = getRecordingBarWindow()
    if (recordingBar) {
      recordingBar.webContents.send(IPC_CHANNELS.RECORDING_TOGGLE)
    }
  })

  // API handlers
  ipcMain.handle(IPC_CHANNELS.API_TEST_KEY, async (_event, key: string) => {
    const result = await testApiKey(key)
    if (result.valid) {
      // Reset clients to use new key
      resetWhisperClient()
      resetCleanupClient()
    }
    return result
  })

  ipcMain.handle(IPC_CHANNELS.API_TRANSCRIBE, async (_event, audioBuffer: ArrayBuffer) => {
    console.log('IPC: Received transcribe request, buffer size:', audioBuffer?.byteLength)
    const result = await transcribeAudio(audioBuffer)
    console.log('IPC: Transcription result:', result)
    return result
  })

  ipcMain.handle(IPC_CHANNELS.API_CLEANUP, async (_event, text: string) => {
    return await cleanupText(text)
  })

  ipcMain.handle(IPC_CHANNELS.TEXT_INSERT, async (_event, text: string) => {
    return await insertText(text)
  })

  ipcMain.handle(IPC_CHANNELS.RECORDING_STOP_AND_INSERT, async (_event, text: string) => {
    console.log('IPC: Stop and insert called, text length:', text?.length ?? 0)

    // Hide the recording bar first
    hideRecordingBar()

    // Wait for window to hide and focus to switch
    await new Promise((resolve) => setTimeout(resolve, 150))

    // Insert the text if there is any
    if (text && text.trim().length > 0) {
      // Apply AI cleanup to the full transcript (if enabled in settings)
      console.log('IPC: Applying AI cleanup to full transcript...')
      const cleanedResult = await cleanupText(text)
      const finalText = cleanedResult.text || text

      if (cleanedResult.error) {
        console.log('IPC: AI cleanup error (using original):', cleanedResult.error)
      } else if (finalText !== text) {
        console.log('IPC: AI cleanup applied, new length:', finalText.length)
      } else {
        console.log('IPC: AI cleanup skipped or no changes')
      }

      console.log('IPC: Inserting text...')
      const result = await insertText(finalText)
      console.log('IPC: Insert result:', result)
      return result
    }

    return { success: true }
  })

  ipcMain.handle(IPC_CHANNELS.AUDIO_CHUNK, async (_event, _payload) => {
    // TODO: Implement in Phase 4/5
    return { success: true }
  })
}

app.whenReady().then(async () => {
  // Check microphone permission on startup
  const hasMicPermission = await checkMicrophonePermission()
  if (!hasMicPermission) {
    console.warn('Microphone permission not granted')
    // Could show an alert here, but we'll let the user handle it in settings
  }

  // Setup IPC handlers
  setupIpcHandlers()

  // Create system tray
  createTray()

  // Start hotkey listener (recording bar window will be created on first use)
  hotkeyManager.start()

  hotkeyManager.on('hotkey-error', (error) => {
    console.error('Failed to register hotkey:', error)
    // Could show an alert about the hotkey conflict
  })

  hotkeyManager.on('trigger', () => {
    // Toggle the recording bar - only show if not already visible
    const recordingBar = getRecordingBarWindow()
    if (recordingBar && recordingBar.isVisible()) {
      // Window is visible, let the toggle IPC handle stopping/hiding
      console.log('HotkeyManager: Recording bar visible, toggle will handle it')
    } else {
      // Window not visible, show it
      console.log('HotkeyManager: Recording bar not visible, showing it')
      showRecordingBar()
    }
  })

  // Create main window (only in dev mode)
  createWindow()

  // Hide dock icon in production (macOS)
  if (!process.env.VITE_DEV_SERVER_URL && process.platform === 'darwin') {
    const showInDock = getSetting('showInDock')
    if (!showInDock) {
      app.dock?.hide()
    }
  }

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow()
    }
  })
})

app.on('window-all-closed', () => {
  // On macOS, keep the app running in the background (tray)
  if (process.platform !== 'darwin') {
    app.quit()
  }
})

app.on('before-quit', () => {
  hotkeyManager.stop()
  destroyAllWindows()
})
