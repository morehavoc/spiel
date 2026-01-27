import { BrowserWindow, Tray, Menu, app, nativeImage, screen } from 'electron'
import path from 'path'
import { getSetting, setSetting } from '../store'
import { savePreviousApp } from './textInserter'

let tray: Tray | null = null
let recordingBarWindow: BrowserWindow | null = null
let settingsWindow: BrowserWindow | null = null
let previouslyFocusedWindow: { pid: number; name: string } | null = null

const isDev = process.env.VITE_DEV_SERVER_URL !== undefined

// Get the path to the dist-electron directory
function getElectronDistPath(): string {
  if (isDev) {
    return path.join(process.cwd(), 'dist-electron')
  }
  // In production, the app is packaged and files are relative to app.getAppPath()
  return path.join(app.getAppPath(), 'dist-electron')
}

function getPreloadPath(): string {
  return path.join(getElectronDistPath(), 'preload.js')
}

function getAssetPath(filename: string): string {
  if (isDev) {
    return path.join(process.cwd(), 'resources', filename)
  }
  return path.join(process.resourcesPath, filename)
}

export function createTray(): Tray {
  // Create a simple 16x16 tray icon (placeholder)
  const icon = nativeImage.createEmpty()
  tray = new Tray(icon)

  updateTrayMenu()
  tray.setToolTip('Spiel - Voice Dictation')

  return tray
}

export function updateTrayMenu(isRecording = false): void {
  if (!tray) return

  const contextMenu = Menu.buildFromTemplate([
    {
      label: isRecording ? 'Stop Recording' : 'Start Recording',
      click: () => {
        // This will be connected to the hotkey manager
        if (recordingBarWindow) {
          recordingBarWindow.webContents.send('recording:toggle')
        }
      },
    },
    { type: 'separator' },
    {
      label: 'Settings...',
      click: () => showSettingsWindow(),
    },
    { type: 'separator' },
    {
      label: 'Quit Spiel',
      click: () => app.quit(),
    },
  ])

  tray.setContextMenu(contextMenu)
}

export function setTrayRecordingState(isRecording: boolean): void {
  updateTrayMenu(isRecording)
  // TODO: Update tray icon when we have actual icons
}

export function createRecordingBarWindow(): BrowserWindow {
  const savedPosition = getSetting('recordingBarPosition')
  const display = screen.getPrimaryDisplay()
  const { width: screenWidth } = display.workAreaSize

  // Default position: top-center of screen
  const windowWidth = 450
  const windowHeight = 300
  const defaultX = Math.round((screenWidth - windowWidth) / 2)
  const defaultY = 50

  recordingBarWindow = new BrowserWindow({
    width: windowWidth,
    height: windowHeight,
    x: savedPosition?.x ?? defaultX,
    y: savedPosition?.y ?? defaultY,
    frame: false,
    transparent: true,
    alwaysOnTop: true,
    skipTaskbar: true,
    resizable: true,
    minWidth: 300,
    minHeight: 150,
    maxHeight: 600,
    show: false,
    webPreferences: {
      preload: getPreloadPath(),
      contextIsolation: true,
      nodeIntegration: false,
    },
  })

  // Save position when moved
  recordingBarWindow.on('moved', () => {
    if (recordingBarWindow) {
      const [x, y] = recordingBarWindow.getPosition()
      setSetting('recordingBarPosition', { x, y })
    }
  })

  recordingBarWindow.on('closed', () => {
    recordingBarWindow = null
  })

  // Load the recording bar route
  if (isDev) {
    recordingBarWindow.loadURL(`${process.env.VITE_DEV_SERVER_URL}#/recording-bar`)
  } else {
    recordingBarWindow.loadFile(path.join(app.getAppPath(), 'dist', 'index.html'), {
      hash: '/recording-bar',
    })
  }

  return recordingBarWindow
}

export async function showRecordingBar(): Promise<void> {
  // Save the currently focused app before showing our window
  await savePreviousApp()

  if (!recordingBarWindow) {
    createRecordingBarWindow()
  }
  console.log('WindowManager: Showing recording bar')
  recordingBarWindow?.show()
}

export function hideRecordingBar(): void {
  console.log('WindowManager: Hiding recording bar')
  recordingBarWindow?.hide()
}

export function getRecordingBarWindow(): BrowserWindow | null {
  return recordingBarWindow
}

export function createSettingsWindow(): BrowserWindow {
  if (settingsWindow && !settingsWindow.isDestroyed()) {
    settingsWindow.focus()
    return settingsWindow
  }

  settingsWindow = new BrowserWindow({
    width: 500,
    height: 600,
    title: 'Spiel Settings',
    resizable: false,
    minimizable: false,
    maximizable: false,
    webPreferences: {
      preload: getPreloadPath(),
      contextIsolation: true,
      nodeIntegration: false,
    },
  })

  settingsWindow.on('closed', () => {
    settingsWindow = null
  })

  // Load the settings route
  if (isDev) {
    settingsWindow.loadURL(`${process.env.VITE_DEV_SERVER_URL}#/settings`)
  } else {
    settingsWindow.loadFile(path.join(app.getAppPath(), 'dist', 'index.html'), {
      hash: '/settings',
    })
  }

  return settingsWindow
}

export function showSettingsWindow(): void {
  createSettingsWindow()
  settingsWindow?.show()
  settingsWindow?.focus()
}

export function getSettingsWindow(): BrowserWindow | null {
  return settingsWindow
}

// Track previously focused window for text insertion
export function savePreviouslyFocusedWindow(): void {
  // Note: Getting the previously focused app requires AppleScript on macOS
  // This is a placeholder - will be implemented with proper macOS integration
  previouslyFocusedWindow = null
}

export function getPreviouslyFocusedWindow(): { pid: number; name: string } | null {
  return previouslyFocusedWindow
}

export function restoreFocusToPreviousWindow(): void {
  // This will use AppleScript to restore focus
  // Placeholder for now
}

export function destroyAllWindows(): void {
  if (recordingBarWindow && !recordingBarWindow.isDestroyed()) {
    recordingBarWindow.destroy()
  }
  if (settingsWindow && !settingsWindow.isDestroyed()) {
    settingsWindow.destroy()
  }
  if (tray) {
    tray.destroy()
  }
  recordingBarWindow = null
  settingsWindow = null
  tray = null
}
