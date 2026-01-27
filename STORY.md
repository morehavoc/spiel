# Building a Voice Dictation App in One Evening with Claude

Last night, I decided I wanted a simple voice-to-text app for my Mac. Something that would let me double-tap Control, speak naturally, and have the words appear wherever I was typing. No switching apps, no clicking buttons—just talk and type.

I could have searched for existing apps, but I had a better idea: build it with Claude.

## The Vision

The concept was straightforward:
- Double-tap Control to start recording
- Speak naturally, see live transcription
- Double-tap again to stop and paste the text
- Optional AI cleanup to fix grammar and remove "ums"

## The Reality

What followed was a surprisingly fluid back-and-forth. Claude scaffolded the Electron + React + TypeScript project, set up the OpenAI Whisper integration, and implemented voice activity detection—all while I tested and provided feedback.

When the audio kept getting rejected as "corrupted," we debugged together and discovered WebM files need their header chunk preserved. When text wasn't pasting into the right app, we traced through the AppleScript focus management. When I said "the window should hide when I stop talking," Claude made it happen.

The most interesting part? The conversation felt collaborative. I'd say things like "what if I'm still talking while it's processing?" and Claude would explain the architecture, then ask how I wanted to handle it. We landed on a solution where stopping waits for pending transcriptions to finish.

## Small Touches That Matter

Some features emerged organically:
- Press Enter while recording to add a line break
- AI cleanup runs on the *full* transcript (not per-chunk) so it has context
- A gear icon in the recording bar for quick settings access

Each came from a simple "can you also add..." and worked on the first try.

## The Result

**Spiel**: A 450×300 floating window that appears when I double-tap Control, shows my words as I speak them, and pastes the cleaned-up text when I'm done. Built in an evening, open source, and actually useful.

The code is at [github.com/morehavoc/spiel](https://github.com/morehavoc/spiel) if you want to try it yourself.

---

*What struck me most wasn't the speed—it was how natural it felt to describe what I wanted and iterate toward it. The future of building software might just be a conversation.*
