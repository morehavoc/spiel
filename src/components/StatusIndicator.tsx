import type { RecordingState } from '../types/electron.d'

interface StatusIndicatorProps {
  state: RecordingState
}

export function StatusIndicator({ state }: StatusIndicatorProps) {
  const getStatusConfig = () => {
    switch (state) {
      case 'recording':
        return {
          color: 'bg-red-500',
          pulse: true,
          text: 'Recording',
        }
      case 'processing':
        return {
          color: 'bg-yellow-500',
          pulse: true,
          text: 'Processing',
        }
      case 'error':
        return {
          color: 'bg-red-600',
          pulse: false,
          text: 'Error',
        }
      default:
        return {
          color: 'bg-gray-500',
          pulse: false,
          text: 'Ready',
        }
    }
  }

  const config = getStatusConfig()

  return (
    <div className="flex items-center gap-2">
      <div
        className={`w-3 h-3 rounded-full ${config.color} ${
          config.pulse ? 'animate-pulse' : ''
        }`}
      />
      <span className="text-sm text-gray-300 font-medium">{config.text}</span>
    </div>
  )
}
