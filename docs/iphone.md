---
title: Spiel Listen for iPhone
nav_order: 5
---

# Spiel Listen for iPhone

Spiel Listen records a meeting on your iPhone and writes a live transcript as it goes. The
speech recognition runs on the phone, so a transcript only leaves it if you share it, run a
Shortcut with it, or back up the phone.

## Getting it

Spiel Listen is in testing through Apple's TestFlight, by invitation; email spiel@christophermoravec.com if you'd like to try it. It's coming to the App Store.
It needs an iPhone with iOS 17 or later; there's no iPad version.

It's a separate app from the Mac app and doesn't sync with it. To move a transcript to your
Mac, use Share or the Files app (see [Your transcripts](#your-transcripts)). How it differs
from the Mac app on languages and vocabulary is in the [FAQ](faq.md).

## First launch

Spiel asks before downloading its speech model, a one-time download of about 500 MB, so
Wi-Fi is a good idea. You can choose **Later** and tap **Download speech model** on the home
screen when you're ready. Setup then shows two steps:

1. **Downloading**, with a percentage.
2. **Preparing for the Neural Engine**, where iOS converts the model for your phone's chip.
   It happens once (and again after some iOS updates) and can take a few minutes. Keep Spiel
   open while it runs, because iOS pauses it in the background.

After that, Spiel works without the internet.

## Recording a meeting

1. Tap **New meeting**.
2. Pick a title: the meeting on your calendar right now, the date and time, or your own.
3. If you want, turn on **Add location** to note where the meeting is. Spiel uses the
   calendar event's location if it has one; otherwise it looks up where your phone is once
   you start. The switch stays
   on for your next meeting until you turn it off.
4. If you want, turn on **Keep audio** to save the recording next to the transcript (about
   14 MB an hour).
5. Tap **Start listening**.

The transcript appears a moment after each pause. Recording keeps going with the screen
locked. A phone call pauses it, and it picks up again when the call ends.

To pause, tap the pause button, and tap it again to resume. To stop, tap the red stop
button and the transcript is saved. Tap the title to rename it, or use the **⋯** menu to
copy or share it.

## Permissions

Spiel asks the first time it needs each one:

- **Microphone**, when you first start listening. This one is required.
- **Calendars** (full access), when you open New meeting. Spiel uses it to offer a
  meeting from around now as the title, and that meeting's location when Add location is on.
- **Location** (while using the app), when you turn on Add location.

To change one later, open the iOS **Settings** app, find **Spiel Listen**, and turn
Microphone, Calendars or Location on or off.

## Your transcripts

Tap the books button at the top left to see all your transcripts, search them, and open one
to read, copy or share it.

- In the **⋯** menu, **Share text…**, **Share Markdown file…** and **Share audio…** (when you
  kept the audio) send it on. **Copy text** copies without timestamps, and **Copy with
  timestamps** keeps them.
- To delete one, swipe left on it in the transcripts list and tap **Delete**. That deletes
  the transcript and its audio recording.
- In the Files app, go to **On My iPhone**, open **Spiel Listen**, then **Spiel →
  Transcripts**. Kept audio (`.m4a`) is in the same folder. You can also copy them to a Mac
  with Finder: connect the iPhone, select it, and open **Files**.
- Transcripts and kept audio are included in your iPhone backup (iCloud or your Mac). The
  speech model isn't.

**Deleting the app deletes all your transcripts and recordings.** Copy the Transcripts
folder somewhere else first if you want to keep them.

## Run a Shortcut when Listen stops

⋯ menu → **Shortcut When Listen Stops**. See [the Shortcuts guide](shortcuts.md).
