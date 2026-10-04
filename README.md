# Spiel

Dictation for the Mac that runs entirely on the Mac. Press a shortcut, talk, and the
text goes into whatever app you're using. No account, no subscription, nothing sent
anywhere.

![Spiel dictating into a text field](native/docs/media/spiel-v2-demo.gif)

- **Dictation.** ⌘⇧D to start and stop, or hold to talk. Works in any app.
- **Listen.** ⌘⇧L records a whole meeting or talk to a Markdown transcript with timestamps.
- **Vocabulary.** Teach it names and jargon it gets wrong.
- **History.** Your last 50 dictations, searchable.
- **Command line.** `spiel transcribe meeting.m4a` turns any audio or video file into
  text, Markdown, SRT, VTT or JSON. Built for scripts and AI agents.

Speech recognition is NVIDIA's Parakeet running on the Neural Engine. Requires an
Apple silicon Mac and macOS 14 or later.

## Get it

- **Signed build with automatic updates:** $19 on Gumroad, with a 14-day free trial,
  for 2 Macs. Available with the first release.
- **Build it yourself, free:** see [native/README.md](native/README.md#building).
  Builds from source have no trial or license check.

## Command line

```bash
spiel transcribe meeting.m4a                  # text to stdout
spiel transcribe talk.mp4 -f srt -o talk.srt  # also md, vtt, json
spiel transcripts                              # Listen transcripts, newest first
spiel doctor                                   # models, versions, permissions
```

Install it from the Spiel menu: Help → Install Command Line Tool.

## License

GPL-3.0. See [LICENSE](LICENSE) and [third-party notices](native/THIRD_PARTY_NOTICES.md).

The original Electron version of Spiel, which used OpenAI's Whisper API, is still in
`electron/` and `src/`.
