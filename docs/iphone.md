---
title: Spiel Listen for iPhone
nav_order: 5
---

# Spiel Listen for iPhone

Spiel Listen records a meeting on your iPhone and writes a live transcript, using a Parakeet
speech model on the phone itself. Spiel never sends your audio or transcripts anywhere;
they leave the phone only if you share them, run a Shortcut, or back up the phone.

## Getting it

- Spiel Listen is in testing (TestFlight) now and free. It is coming to the App Store.
- It needs an iPhone with iOS 17 or later. There is no iPad version.
- It is a separate app from the Mac app. It does not sync with your Mac; to move a
  transcript, use Share or the Files app (see [Your transcripts](#your-transcripts)).
- It uses Parakeet v3, the multilingual model. It has no Vocabulary editor.

## First launch

Spiel asks before downloading its speech model. It's a one-time download of about
500 MB. Wi-Fi is recommended. You can choose **Later** and tap **Download
speech model** on the home screen when you're ready. Setup then shows two steps:

1. **Downloading**, with a percentage.
2. **Preparing for the Neural Engine.** iOS converts the model for your phone's chip. It
   happens once (and again after some iOS updates) and can take a few minutes. Keep Spiel
   open while it runs; iOS pauses it in the background.

After that, Spiel works with no internet.

## Recording a meeting

1. Tap **New meeting**.
2. Pick a title: the meeting on your calendar right now, the date and time, or your own.
3. Optional: turn on **Add location** to note where the meeting is. Spiel uses the calendar
   event's location if it has one, otherwise where your phone is.
4. Optional: turn on **Keep audio** to save the recording next to the transcript (about
   14 MB an hour).
5. Tap **Start listening**.

The transcript appears a moment after each pause. Recording keeps going with the screen
locked. A phone call pauses it, and it picks up again when the call ends.

- **Pause:** tap the pause button. Tap it again to resume.
- **Stop:** tap the red stop button. The transcript is saved.
- **Rename, copy or share:** tap the title to rename it, or use the **⋯** menu.

## Permissions

Spiel asks the first time it needs each one:

- **Microphone**, when you first start listening. Required.
- **Calendars** (full access), when you open New meeting. Optional: only used to offer the
  current meeting as the title.
- **Location** (while using the app), when you turn on Add location. Optional.

If you said no and want to change it, open the iOS **Settings** app, find Spiel (it may be
listed as **Spiel Listen**), and turn on Microphone, Calendars or Location. You can turn them off the same way.

## Your transcripts

Tap the books button at the top left to see all transcripts, search them, and open one to
read, copy or share it.

- **Share:** ⋯ → **Share text…**, **Share Markdown file…** or **Share audio…** (when you kept
  the audio). **Copy text** copies without timestamps; **Copy with timestamps** keeps them.
- **Delete:** in the transcripts list, swipe left on a transcript and tap **Delete**. This
  deletes the transcript and its audio recording.
- **In the Files app:** go to **On My iPhone**, open Spiel's folder (look for **Spiel
  Listen**), then **Spiel → Transcripts**. Kept audio (`.m4a`) is in the same folder. You can
  also copy them to a Mac with Finder: connect the iPhone, select it, and open **Files**.
- They are included in your iPhone backup (iCloud or your Mac). The speech model is not.
- **Deleting the app deletes them.** Copy the Transcripts folder somewhere else first if you
  want to keep them.

## Run a Shortcut when Listen stops

⋯ menu → **Shortcut When Listen Stops**. See [the Shortcuts guide](shortcuts.md).
