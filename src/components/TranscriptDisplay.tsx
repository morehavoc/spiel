import { useEffect, useRef } from 'react'

interface TranscriptDisplayProps {
  text: string
  isProcessing: boolean
}

export function TranscriptDisplay({ text, isProcessing }: TranscriptDisplayProps) {
  const containerRef = useRef<HTMLDivElement>(null)

  // Auto-scroll to bottom when text changes
  useEffect(() => {
    if (containerRef.current) {
      containerRef.current.scrollTop = containerRef.current.scrollHeight
    }
  }, [text])

  if (!text && !isProcessing) {
    return (
      <div className="flex-1 min-h-0 text-gray-500 text-sm italic">
        Start speaking...
      </div>
    )
  }

  return (
    <div
      ref={containerRef}
      className="flex-1 min-h-0 overflow-y-auto text-sm text-white leading-relaxed whitespace-pre-wrap"
    >
      {text}
      {isProcessing && (
        <span className="inline-block ml-1 animate-pulse">
          <span className="text-blue-400">...</span>
        </span>
      )}
    </div>
  )
}
