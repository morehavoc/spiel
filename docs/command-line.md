---
title: Command line
nav_order: 6
---

# The `spiel` command

Install it from the Spiel menu: Help → **Install Command Line Tool…**. It uses the app's
speech model, vocabulary and settings.

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
errors go to stderr. Exit codes: **0** ok, **1** usage, **2** file unreadable or not audio,
**3** engine failure, **4** no speech found, **5** no license.

The full JSON format and options are in the
[developer notes](https://github.com/morehavoc/spiel/blob/main/native/README.md#for-ai-agents).
