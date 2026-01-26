# Spiel

A macOS desktop app for voice-to-text dictation using OpenAI's Whisper API. Press a hotkey, speak naturally, and have your words transcribed and inserted into any application.

## Features

- **Global Hotkey**: Double-tap Control (or F5, or custom shortcut) to start/stop recording from anywhere
- **Real-time Transcription**: Uses OpenAI's `gpt-4o-mini-transcribe` model for accurate speech-to-text
- **Voice Activity Detection**: Automatically detects pauses in speech to send audio for transcription
- **AI Text Cleanup**: Optional GPT-4o-mini post-processing to fix grammar and remove filler words
- **Universal Text Insertion**: Automatically pastes transcribed text into any active application
- **Floating Recording Bar**: Minimal, draggable UI showing waveform and live transcript
- **Menu Bar App**: Runs quietly in your menu bar with quick access to settings

## Requirements

- macOS 10.15 or later
- OpenAI API key with access to audio transcription
- Microphone access permission
- Accessibility permission (for global hotkey detection)

## Installation

### From DMG (Recommended)

1. Download the latest `.dmg` from the releases
2. Open the DMG and drag Spiel to your Applications folder
3. Launch Spiel from Applications
4. Grant microphone and accessibility permissions when prompted
5. Open Settings from the menu bar icon and enter your OpenAI API key

### From Source

```bash
# Clone the repository
git clone https://github.com/yourusername/spiel.git
cd spiel

# Install dependencies
npm install

# Run in development mode
npm run dev

# Build for production
npm run build:mac
```

## Usage

1. **Start Recording**: Double-tap the Control key (or your configured hotkey)
2. **Speak**: Talk naturally - the app detects when you pause
3. **Stop Recording**: Double-tap Control again (or wait for extended silence)
4. **Text Inserted**: Your transcription is automatically pasted into the active application

### Settings

Access settings from the menu bar icon:

- **API Key**: Your OpenAI API key (stored encrypted)
- **Hotkey**: Choose between double-tap Control, F5, or a custom shortcut
- **Silence Duration**: How long to wait after speech before processing (default: 900ms)
- **Language Hint**: Improve accuracy by specifying your primary language
- **AI Cleanup**: Enable/disable grammar correction and filler word removal
- **Insertion Method**: Paste (faster) or type character-by-character

## Development

```bash
# Run development server with hot reload
npm run dev

# Type check
npm run typecheck

# Build for macOS
npm run build:mac
```

### Project Structure

```
spiel/
├── electron/           # Main process (Node.js)
│   ├── main.ts         # App entry point
│   ├── preload.ts      # Context bridge for IPC
│   └── services/       # Core services
│       ├── hotkeyManager.ts    # Global hotkey detection
│       ├── whisperApi.ts       # OpenAI transcription
│       ├── aiCleanup.ts        # Text post-processing
│       ├── textInserter.ts     # Clipboard/paste handling
│       └── windowManager.ts    # Window management
├── src/                # Renderer process (React)
│   ├── windows/        # RecordingBar, Settings
│   ├── components/     # UI components
│   ├── hooks/          # React hooks
│   └── stores/         # Zustand state
└── resources/          # App icons and assets
```

### Tech Stack

- **Electron** - Cross-platform desktop framework
- **React 18** - UI framework
- **TypeScript** - Type safety
- **Vite** - Build tool
- **Tailwind CSS** - Styling
- **Zustand** - State management
- **OpenAI SDK** - API client
- **uiohook-napi** - Global keyboard hooks

## Permissions

Spiel requires the following macOS permissions:

- **Microphone**: Required for voice recording
- **Accessibility**: Required for global hotkey detection and text insertion

You can grant these in System Preferences > Privacy & Security.

## Troubleshooting

### Hotkey not working
- Ensure Spiel has Accessibility permission in System Preferences
- Try restarting the app after granting permissions

### Transcription failing
- Verify your OpenAI API key is valid (use the Test button in Settings)
- Check that your API key has access to audio transcription endpoints
- Ensure you have sufficient API credits

### Text not being inserted
- Grant Accessibility permission for keyboard simulation
- Try switching to "Type Characters" insertion method in Settings

## Privacy

- Audio is sent to OpenAI's API for transcription (not stored locally)
- Your API key is encrypted using macOS Keychain
- No telemetry or usage data is collected

## License

This project is licensed under a Non-Commercial License. You are free to use, modify, and distribute this software for personal and non-commercial purposes. Commercial use and selling of this software is prohibited. See the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [OpenAI](https://openai.com) for the Whisper transcription API
- [Electron](https://electronjs.org) for the desktop framework
- [uiohook-napi](https://github.com/SnosMe/uiohook-napi) for keyboard hook support
