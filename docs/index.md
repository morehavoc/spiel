---
title: Home
nav_order: 1
---

# Spiel

I make Spiel, a dictation app for the Mac. You press a shortcut, talk, and the text goes into
whatever app you're typing in. Speech recognition runs on your Mac, by default using NVIDIA's Parakeet
model on the Neural Engine. There's no account to make and nothing to subscribe to.

![Spiel dictating into a text field](assets/spiel-v2-demo.gif)

## What it does

Press **⌘⇧D** (Command-Shift-D) to start dictating and press it again to stop. If you'd
rather hold the key while you talk, you can switch to that in Settings. It works in most
apps that take text; [password fields](troubleshooting.md#dictating-into-a-password-field)
work a little differently.

The rest of it:

- [Listen](listen.md) (⌘⇧L) records a whole meeting or talk to a text transcript with
  timestamps, and ⌃⌥⌘S drops a screenshot into it at that moment.
- When Listen stops, Spiel can [run one of your Shortcuts](shortcuts.md) with the transcript.
- You can teach it names and jargon it gets wrong in the Vocabulary settings.
- History keeps your last 50 dictations, searchable (you can turn it off).
- If you use Terminal, the [`spiel` command](command-line.md) turns audio and video files
  into text.
- [Spiel Listen](iphone.md) records meetings on the iPhone. It's in testing now and coming
  to the App Store.

## Requirements

- Mac: Apple silicon (M1 or later), macOS 14 or later, and about 700 MB of free disk space
  for the speech model.
- iPhone: iOS 17 or later, and about 500 MB of free space for the speech model.

## Get it

The signed build is [$19 on Gumroad](https://morehavoc.gumroad.com/l/spiel), with a 14-day
free trial and automatic updates. One license covers 2 Macs; see [Licensing](license.md).

Spiel is also open source, so you can build it yourself for free from the
[developer notes](https://github.com/morehavoc/spiel/blob/main/native/README.md#building).

Start with [Getting started](getting-started.md).
