import Store from 'electron-store'
import { safeStorage } from 'electron'

// Settings schema
export interface AppSettings {
  // API
  apiKey: string // Encrypted

  // Hotkey
  hotkeyMode: 'double-tap-control' | 'f5' | 'custom'
  customHotkey: string // e.g., 'CommandOrControl+Shift+D'
  doubleTapThreshold: number // ms

  // Audio/VAD
  silenceDuration: number // ms, default 900
  minSpeechDuration: number // ms, default 500

  // Transcription
  languageHint: string // ISO language code, e.g., 'en'
  aiCleanupEnabled: boolean

  // Text insertion
  insertionMethod: 'paste' | 'type'

  // App behavior
  launchAtLogin: boolean
  showInDock: boolean

  // Window
  recordingBarPosition: { x: number; y: number } | null
}

const defaults: AppSettings = {
  apiKey: '',
  hotkeyMode: 'double-tap-control',
  customHotkey: 'CommandOrControl+Shift+D',
  doubleTapThreshold: 300,
  silenceDuration: 900,
  minSpeechDuration: 500,
  languageHint: 'en',
  aiCleanupEnabled: false,
  insertionMethod: 'paste',
  launchAtLogin: false,
  showInDock: false,
  recordingBarPosition: null,
}

// Create the store
const store = new Store<AppSettings>({
  defaults,
  name: 'settings',
})

// Encrypt/decrypt API key helpers
export function setApiKey(key: string): void {
  if (!key) {
    store.set('apiKey', '')
    return
  }

  if (safeStorage.isEncryptionAvailable()) {
    const encrypted = safeStorage.encryptString(key)
    store.set('apiKey', encrypted.toString('base64'))
  } else {
    // Fallback to plain text (not recommended, but better than nothing)
    console.warn('Encryption not available, storing API key in plain text')
    store.set('apiKey', key)
  }
}

export function getApiKey(): string {
  const stored = store.get('apiKey')
  if (!stored) return ''

  if (safeStorage.isEncryptionAvailable()) {
    try {
      const buffer = Buffer.from(stored, 'base64')
      return safeStorage.decryptString(buffer)
    } catch {
      // If decryption fails, might be plain text from before
      return stored
    }
  }

  return stored
}

// Generic getters/setters for other settings
export function getSetting<K extends keyof AppSettings>(key: K): AppSettings[K] {
  if (key === 'apiKey') {
    return getApiKey() as AppSettings[K]
  }
  return store.get(key)
}

export function setSetting<K extends keyof AppSettings>(key: K, value: AppSettings[K]): void {
  if (key === 'apiKey') {
    setApiKey(value as string)
    return
  }
  store.set(key, value)
}

export function getAllSettings(): AppSettings {
  return {
    ...store.store,
    apiKey: getApiKey(),
  }
}

export function setAllSettings(settings: Partial<AppSettings>): void {
  Object.entries(settings).forEach(([key, value]) => {
    setSetting(key as keyof AppSettings, value)
  })
}

export { store }
