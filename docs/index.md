---
title: Home
nav_order: 1
---

# Spiel

Dictation for the Mac that runs on the Mac. Press a shortcut, talk, and the text goes into
the app you're using. No account, no subscription. Speech recognition happens on your
device, and Spiel never sends what you say anywhere.

![Spiel dictating into a text field](assets/spiel-v2-demo.gif)

- **Dictation.** Press ⌘⇧D (Command-Shift-D) to start and stop. You can switch to
  hold-to-talk in Settings. Works in most apps that take text (see
  [password fields](troubleshooting.md#nothing-is-typed-in-a-password-field)).
- **Listen.** ⌘⇧L records a whole meeting or talk to a text transcript with timestamps.
- **Screenshots.** ⌃⌥⌘S during Listen drops a screenshot into the transcript at that moment.
- **Shortcuts.** Run one of your Shortcuts automatically every time Listen stops.
- **Vocabulary.** Teach it names and jargon it gets wrong.
- **History.** Your last 50 dictations, searchable. You can turn it off.
- **Command line (optional).** `spiel transcribe meeting.m4a` turns an audio or video file
  into text.
- **iPhone.** Spiel Listen records meetings on your phone, the same way. It is in testing
  now and coming to the App Store.

Speech recognition is NVIDIA's Parakeet, running on your Mac's Neural Engine.

## Requirements

- **Mac:** Apple silicon (M1 or later), macOS 14 or later, and about 700 MB of free disk
  space for the speech model.
- **iPhone:** iOS 17 or later, and about 500 MB of free space for the speech model.

## Get it

- **Signed build with automatic updates:** [$19 on Gumroad](https://morehavoc.gumroad.com/l/spiel),
  with a 14-day free trial. One license covers 2 Macs. See [Licensing](license.md).
- **Build it yourself, free:** Spiel is open source. See the
  [developer notes](https://github.com/morehavoc/spiel/blob/main/native/README.md#building).

Start with [Getting started](getting-started.md).
