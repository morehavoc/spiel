import { useEffect, useState } from 'react'
import { RecordingBar } from './windows/RecordingBar'
import { Settings } from './windows/Settings'

type Route = 'recording-bar' | 'settings' | 'main'

function getRouteFromHash(): Route {
  const hash = window.location.hash.slice(1) // Remove the #
  if (hash === '/recording-bar') return 'recording-bar'
  if (hash === '/settings') return 'settings'
  return 'main'
}

function App() {
  const [route, setRoute] = useState<Route>(getRouteFromHash)

  useEffect(() => {
    const handleHashChange = () => {
      setRoute(getRouteFromHash())
    }

    window.addEventListener('hashchange', handleHashChange)
    return () => window.removeEventListener('hashchange', handleHashChange)
  }, [])

  // Render based on route
  switch (route) {
    case 'recording-bar':
      return <RecordingBar />
    case 'settings':
      return <Settings />
    default:
      return <MainWindow />
  }
}

// Main window for development/debugging
function MainWindow() {
  const handleOpenSettings = async () => {
    await window.electronAPI.showSettings()
  }

  const handleToggleRecording = async () => {
    await window.electronAPI.showRecordingBar()
  }

  const handleTestMicrophone = async () => {
    const permissions = await window.electronAPI.getPermissions()
    if (permissions.microphone) {
      alert('Microphone permission granted!')
    } else {
      const granted = await window.electronAPI.requestMicrophonePermission()
      alert(granted ? 'Microphone permission granted!' : 'Microphone permission denied')
    }
  }

  return (
    <div className="min-h-screen bg-gray-900 text-white flex flex-col items-center justify-center p-8">
      <div className="text-center space-y-6">
        <h1 className="text-4xl font-bold">Spiel</h1>
        <p className="text-gray-400 text-lg">Voice-to-text dictation for macOS</p>

        <div className="space-y-3">
          <button
            onClick={handleToggleRecording}
            className="block w-full px-6 py-3 bg-blue-600 hover:bg-blue-700 text-white rounded-lg font-medium transition-colors"
          >
            Show Recording Bar
          </button>

          <button
            onClick={handleOpenSettings}
            className="block w-full px-6 py-3 bg-gray-700 hover:bg-gray-600 text-white rounded-lg font-medium transition-colors"
          >
            Open Settings
          </button>

          <button
            onClick={handleTestMicrophone}
            className="block w-full px-6 py-3 bg-gray-700 hover:bg-gray-600 text-white rounded-lg font-medium transition-colors"
          >
            Test Microphone Permission
          </button>
        </div>

        <div className="text-sm text-gray-500 space-y-1">
          <p>Double-tap Control to start/stop recording</p>
          <p>Or use the tray icon in the menu bar</p>
        </div>
      </div>
    </div>
  )
}

export default App
