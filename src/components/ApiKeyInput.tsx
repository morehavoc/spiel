import { useState, useCallback } from 'react'

interface ApiKeyInputProps {
  value: string
  onChange: (value: string) => void
  onTest?: (key: string) => Promise<{ valid: boolean; error?: string }>
}

export function ApiKeyInput({ value, onChange, onTest }: ApiKeyInputProps) {
  const [isVisible, setIsVisible] = useState(false)
  const [isTesting, setIsTesting] = useState(false)
  const [testResult, setTestResult] = useState<{ valid: boolean; error?: string } | null>(null)

  const handleTest = useCallback(async () => {
    if (!value || !onTest) return

    setIsTesting(true)
    setTestResult(null)

    try {
      const result = await onTest(value)
      setTestResult(result)
    } catch (error) {
      setTestResult({
        valid: false,
        error: error instanceof Error ? error.message : 'Test failed',
      })
    } finally {
      setIsTesting(false)
    }
  }, [value, onTest])

  return (
    <div className="space-y-2">
      <label className="block text-sm font-medium text-gray-300">
        OpenAI API Key
      </label>
      <div className="flex gap-2">
        <div className="relative flex-1">
          <input
            type={isVisible ? 'text' : 'password'}
            value={value}
            onChange={(e) => {
              onChange(e.target.value)
              setTestResult(null)
            }}
            placeholder="sk-..."
            className="w-full px-3 py-2 bg-gray-800 border border-gray-700 rounded-lg text-white placeholder-gray-500 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
          />
          <button
            type="button"
            onClick={() => setIsVisible(!isVisible)}
            className="absolute right-2 top-1/2 -translate-y-1/2 text-gray-400 hover:text-gray-300"
          >
            {isVisible ? (
              <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M13.875 18.825A10.05 10.05 0 0112 19c-4.478 0-8.268-2.943-9.543-7a9.97 9.97 0 011.563-3.029m5.858.908a3 3 0 114.243 4.243M9.878 9.878l4.242 4.242M9.88 9.88l-3.29-3.29m7.532 7.532l3.29 3.29M3 3l3.59 3.59m0 0A9.953 9.953 0 0112 5c4.478 0 8.268 2.943 9.543 7a10.025 10.025 0 01-4.132 5.411m0 0L21 21" />
              </svg>
            ) : (
              <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z" />
              </svg>
            )}
          </button>
        </div>
        {onTest && (
          <button
            type="button"
            onClick={handleTest}
            disabled={!value || isTesting}
            className="px-4 py-2 bg-blue-600 hover:bg-blue-700 disabled:bg-gray-700 disabled:cursor-not-allowed text-white rounded-lg font-medium transition-colors"
          >
            {isTesting ? 'Testing...' : 'Test'}
          </button>
        )}
      </div>
      {testResult && (
        <p
          className={`text-sm ${
            testResult.valid ? 'text-green-400' : 'text-red-400'
          }`}
        >
          {testResult.valid ? 'API key is valid!' : testResult.error || 'Invalid API key'}
        </p>
      )}
    </div>
  )
}
