import { app, BrowserWindow, ipcMain, systemPreferences } from 'electron'
import path from 'path'
import { IPC_CHANNELS } from './ipc'
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
  if (process.env.VITE_DEV_SERVER_URL) {
    mainWindow = new BrowserWindow({
      width: 800,
      height: 600,
      webPreferences: {
        preload: path.join(__dirname, 'preload.js'),
        contextIsolation: true,
        nodeIntegration: false,
      },
    })

    mainWindow.loadURL(process.env.VITE_DEV_SERVER_URL)
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
    return await transcribeAudio(audioBuffer)
  })

  ipcMain.handle(IPC_CHANNELS.API_CLEANUP, async (_event, text: string) => {
    return await cleanupText(text)
  })

  ipcMain.handle(IPC_CHANNELS.TEXT_INSERT, async (_event, text: string) => {
    return await insertText(text)
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

  // Create recording bar window (hidden initially)
  const recordingBar = createRecordingBarWindow()

  // Start hotkey listener
  hotkeyManager.setRecordingBarWindow(recordingBar)
  hotkeyManager.start()

  hotkeyManager.on('accessibility-error', (error) => {
    console.error('Accessibility permission required:', error)
    // Could show an alert prompting user to grant accessibility permissions
  })

  hotkeyManager.on('trigger', () => {
    // Show the recording bar when hotkey is triggered
    showRecordingBar()
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
