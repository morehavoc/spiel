interface WaveformProps {
  data: number[]
  isActive: boolean
}

export function Waveform({ data, isActive }: WaveformProps) {
  return (
    <div className="flex items-center justify-center gap-0.5 h-8">
      {data.map((value, index) => {
        // Convert -1 to 1 range to 0 to 1 for height
        const normalizedHeight = Math.abs(value)
        const minHeight = 2
        const maxHeight = 24
        const height = minHeight + normalizedHeight * (maxHeight - minHeight)

        return (
          <div
            key={index}
            className={`w-1 rounded-full transition-all duration-75 ${
              isActive ? 'bg-blue-400' : 'bg-gray-600'
            }`}
            style={{ height: `${height}px` }}
          />
        )
      })}
    </div>
  )
}
