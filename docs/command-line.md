---
title: Command line
nav_order: 6
---

# The `spiel` command

This is for people who use Terminal. You don't need it to dictate or record meetings. It
uses the app's speech model, vocabulary and settings.

## Install

1. In the Spiel menu, choose **Help → Install Command Line Tool…**.
2. Click **Install**. Spiel adds `spiel` to `~/.local/bin`, a folder in your home folder.
3. If you move Spiel.app later, install it again.

If `~/.local/bin` isn't on your PATH, Spiel tells you. In that case, when `/usr/local/bin`
is on your PATH and you can write to it, Spiel also offers **Install in /usr/local/bin**.

If Terminal says `command not found: spiel`, add `~/.local/bin` to your PATH by running
this once, then open a new Terminal window:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

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

It reads anything macOS can play: wav, aiff, caf, m4a, mp3, aac, mp4 and mov.

## Scripting

For scripts and AI agents, run `spiel transcribe <file> -f json -q`. Only the result goes
to stdout; progress and errors go to stderr.

Exit codes:

- 0 means it worked.
- 1 is a usage error.
- 2 means the file was unreadable, missing or not audio.
- 3 is an engine or model failure. That includes a partial transcript, where some segments
  failed and the output holds what did transcribe.
- 4 means no speech was found.
- 5 means there's no license (the trial is over or the license was turned off), and
  nothing was transcribed.

The full JSON format and options are in the
[developer notes](https://github.com/morehavoc/spiel/blob/main/native/README.md#for-ai-agents).
