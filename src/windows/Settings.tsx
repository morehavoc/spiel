import { useEffect, useState, useCallback } from 'react'
import { ApiKeyInput } from '../components/ApiKeyInput'
import type { AppSettings } from '../types/electron.d'

const LANGUAGE_OPTIONS = [
  { value: 'en', label: 'English' },
  { value: 'es', label: 'Spanish' },
  { value: 'fr', label: 'French' },
  { value: 'de', label: 'German' },
  { value: 'it', label: 'Italian' },
  { value: 'pt', label: 'Portuguese' },
  { value: 'nl', label: 'Dutch' },
  { value: 'pl', label: 'Polish' },
  { value: 'ru', label: 'Russian' },
  { value: 'ja', label: 'Japanese' },
  { value: 'ko', label: 'Korean' },
  { value: 'zh', label: 'Chinese' },
]

export function Settings() {
  const [settings, setSettings] = useState<AppSettings | null>(null)
  const [isSaving, setIsSaving] = useState(false)

  // Load settings on mount
  useEffect(() => {
    window.electronAPI.getAllSettings().then(setSettings)
  }, [])

  const updateSetting = useCallback(
    async <K extends keyof AppSettings>(key: K, value: AppSettings[K]) => {
      if (!settings) return

      setSettings({ ...settings, [key]: value })
      setIsSaving(true)

      try {
        await window.electronAPI.setSetting(key, value)
      } catch (error) {
        console.error('Failed to save setting:', error)
      } finally {
        setIsSaving(false)
      }
    },
    [settings]
  )

  const handleTestApiKey = useCallback(async (key: string) => {
    return await window.electronAPI.testApiKey(key)
  }, [])

  if (!settings) {
    return (
      <div className="min-h-screen bg-gray-900 text-white flex items-center justify-center">
        <div className="animate-pulse">Loading settings...</div>
      </div>
    )
  }

  return (
    <div className="min-h-screen bg-gray-900 text-white p-6">
      <div className="max-w-xl mx-auto space-y-8">
        <h1 className="text-2xl font-bold">Spiel Settings</h1>

        {/* API Key Section */}
        <section className="space-y-4">
          <h2 className="text-lg font-semibold text-gray-200">API Configuration</h2>
          <ApiKeyInput
            value={settings.apiKey}
            onChange={(value) => updateSetting('apiKey', value)}
            onTest={handleTestApiKey}
          />
        </section>

        {/* Hotkey Section */}
        <section className="space-y-4">
          <h2 className="text-lg font-semibold text-gray-200">Hotkey</h2>

          <div className="space-y-3">
            <label className="block text-sm font-medium text-gray-300">
              Trigger Method
            </label>
            <select
              value={settings.hotkeyMode}
              onChange={(e) =>
                updateSetting('hotkeyMode', e.target.value as AppSettings['hotkeyMode'])
              }
              className="w-full px-3 py-2 bg-gray-800 border border-gray-700 rounded-lg text-white focus:outline-none focus:ring-2 focus:ring-blue-500"
            >
              <option value="double-tap-control">Double-tap Control</option>
              <option value="f5">Double-tap F5</option>
              <option value="custom">Custom Shortcut</option>
            </select>

            {settings.hotkeyMode === 'custom' && (
              <div className="space-y-2">
                <label className="block text-sm font-medium text-gray-300">
                  Custom Shortcut
                </label>
                <input
                  type="text"
                  value={settings.customHotkey}
                  onChange={(e) => updateSetting('customHotkey', e.target.value)}
                  placeholder="e.g., CommandOrControl+Shift+D"
                  className="w-full px-3 py-2 bg-gray-800 border border-gray-700 rounded-lg text-white placeholder-gray-500 focus:outline-none focus:ring-2 focus:ring-blue-500"
                />
                <p className="text-xs text-gray-500">
                  Use Electron accelerator format (e.g., CommandOrControl+Shift+D)
                </p>
              </div>
            )}

            {(settings.hotkeyMode === 'double-tap-control' || settings.hotkeyMode === 'f5') && (
              <div className="space-y-2">
                <label className="block text-sm font-medium text-gray-300">
                  Double-tap Threshold: {settings.doubleTapThreshold}ms
                </label>
                <input
                  type="range"
                  min="150"
                  max="500"
                  step="50"
                  value={settings.doubleTapThreshold}
                  onChange={(e) => updateSetting('doubleTapThreshold', parseInt(e.target.value))}
                  className="w-full"
                />
                <p className="text-xs text-gray-500">
                  Time window to detect a double-tap
                </p>
              </div>
            )}
          </div>
        </section>

        {/* Audio/VAD Section */}
        <section className="space-y-4">
          <h2 className="text-lg font-semibold text-gray-200">Voice Detection</h2>

          <div className="space-y-2">
            <label className="block text-sm font-medium text-gray-300">
              Silence Duration: {settings.silenceDuration}ms
            </label>
            <input
              type="range"
              min="300"
              max="2000"
              step="100"
              value={settings.silenceDuration}
              onChange={(e) => updateSetting('silenceDuration', parseInt(e.target.value))}
              className="w-full"
            />
            <p className="text-xs text-gray-500">
              How long to wait after you stop speaking before processing
            </p>
          </div>
        </section>

        {/* Transcription Section */}
        <section className="space-y-4">
          <h2 className="text-lg font-semibold text-gray-200">Transcription</h2>

          <div className="space-y-2">
            <label className="block text-sm font-medium text-gray-300">
              Language Hint
            </label>
            <select
              value={settings.languageHint}
              onChange={(e) => updateSetting('languageHint', e.target.value)}
              className="w-full px-3 py-2 bg-gray-800 border border-gray-700 rounded-lg text-white focus:outline-none focus:ring-2 focus:ring-blue-500"
            >
              {LANGUAGE_OPTIONS.map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
          </div>

          <div className="flex items-center justify-between">
            <div>
              <label className="text-sm font-medium text-gray-300">
                AI Text Cleanup
              </label>
              <p className="text-xs text-gray-500">
                Use GPT-4o-mini to fix grammar and remove filler words
              </p>
            </div>
            <button
              type="button"
              onClick={() => updateSetting('aiCleanupEnabled', !settings.aiCleanupEnabled)}
              className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors ${
                settings.aiCleanupEnabled ? 'bg-blue-600' : 'bg-gray-700'
              }`}
            >
              <span
                className={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${
                  settings.aiCleanupEnabled ? 'translate-x-6' : 'translate-x-1'
                }`}
              />
            </button>
          </div>

          {settings.aiCleanupEnabled && (
            <div className="space-y-2">
              <label className="block text-sm font-medium text-gray-300">
                AI Cleanup Prompt
              </label>
              <textarea
                value={settings.aiCleanupPrompt}
                onChange={(e) => updateSetting('aiCleanupPrompt', e.target.value)}
                rows={8}
                className="w-full px-3 py-2 bg-gray-800 border border-gray-700 rounded-lg text-white text-sm font-mono placeholder-gray-500 focus:outline-none focus:ring-2 focus:ring-blue-500 resize-y"
                placeholder="Enter the system prompt for AI cleanup..."
              />
              <p className="text-xs text-gray-500">
                Customize how the AI cleans up your transcribed text. You can add custom vocabulary,
                spelling corrections, or specific instructions for how text should be formatted.
              </p>
            </div>
          )}
        </section>

        {/* Text Insertion Section */}
        <section className="space-y-4">
          <h2 className="text-lg font-semibold text-gray-200">Text Insertion</h2>

          <div className="space-y-2">
            <label className="block text-sm font-medium text-gray-300">
              Insertion Method
            </label>
            <select
              value={settings.insertionMethod}
              onChange={(e) =>
                updateSetting('insertionMethod', e.target.value as AppSettings['insertionMethod'])
              }
              className="w-full px-3 py-2 bg-gray-800 border border-gray-700 rounded-lg text-white focus:outline-none focus:ring-2 focus:ring-blue-500"
            >
              <option value="paste">Clipboard Paste (Cmd+V)</option>
              <option value="type">Type Characters</option>
            </select>
            <p className="text-xs text-gray-500">
              Paste is faster, but typing works in more applications
            </p>
          </div>
        </section>

        {/* App Behavior Section */}
        <section className="space-y-4">
          <h2 className="text-lg font-semibold text-gray-200">App Behavior</h2>

          <div className="flex items-center justify-between">
            <div>
              <label className="text-sm font-medium text-gray-300">
                Launch at Login
              </label>
              <p className="text-xs text-gray-500">
                Start Spiel automatically when you log in
              </p>
            </div>
            <button
              type="button"
              onClick={() => updateSetting('launchAtLogin', !settings.launchAtLogin)}
              className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors ${
                settings.launchAtLogin ? 'bg-blue-600' : 'bg-gray-700'
              }`}
            >
              <span
                className={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${
                  settings.launchAtLogin ? 'translate-x-6' : 'translate-x-1'
                }`}
              />
            </button>
          </div>

          <div className="flex items-center justify-between">
            <div>
              <label className="text-sm font-medium text-gray-300">
                Show in Dock
              </label>
              <p className="text-xs text-gray-500">
                Display Spiel icon in the macOS Dock
              </p>
            </div>
            <button
              type="button"
              onClick={() => updateSetting('showInDock', !settings.showInDock)}
              className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors ${
                settings.showInDock ? 'bg-blue-600' : 'bg-gray-700'
              }`}
            >
              <span
                className={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${
                  settings.showInDock ? 'translate-x-6' : 'translate-x-1'
                }`}
              />
            </button>
          </div>
        </section>

        {/* Save indicator */}
        {isSaving && (
          <div className="fixed bottom-4 right-4 bg-gray-800 text-gray-300 px-4 py-2 rounded-lg shadow-lg">
            Saving...
          </div>
        )}
      </div>
    </div>
  )
}
