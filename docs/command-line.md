---
title: Command line
nav_order: 6
---

# The `spiel` command (optional)

This is for people who use Terminal. You don't need it to dictate or record meetings.

## Install

1. In the Spiel menu, choose **Help → Install Command Line Tool…**.
2. Click **Install**. Spiel adds `spiel` to `~/.local/bin` (a folder in your home folder).
   If `/usr/local/bin` is on your PATH and you can write to it, Spiel also offers
   **Install in /usr/local/bin**.
3. If you move Spiel.app, install it again.

**`command not found: spiel`?** `~/.local/bin` is often not on your PATH. Spiel tells you
when it isn't. Add it by running this once, then open a new Terminal window:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

The command uses the app's speech model, vocabulary and settings.

## Use it

```bash
spiel transcribe meeting.m4a                  # text to stdout
spiel transcribe talk.mp4 -f srt -o talk.srt  # also md, vtt, json
cat clip.wav | spiel transcribe - -f json     # stdin
spiel transcribe *.m4a -f vtt -o subs/        # several files → a folder
spiel transcripts                              # Listen transcripts, newest first
spiel transcripts show 1                       # print one
spiel history -n 5                             # recent dictations
spiel doctor                                   # models, versions, permissions
```

It reads anything macOS can play: wav, aiff, caf, m4a, mp3, aac, mp4, mov.

## For scripts and AI agents

Run `spiel transcribe <file> -f json -q`. Only the result goes to stdout; progress and
errors go to stderr.

Exit codes:

- **0** ok
- **1** usage error
- **2** file unreadable, missing or not audio
- **3** engine or model failure, including a partial transcript (some segments failed; the
  output holds what did transcribe)
- **4** no speech found
- **5** no license: the trial is over or the license was revoked. Nothing is transcribed.

The full JSON format and options are in the
[developer notes](https://github.com/morehavoc/spiel/blob/main/native/README.md#for-ai-agents).
