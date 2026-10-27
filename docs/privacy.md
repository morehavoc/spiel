---
title: Privacy policy
nav_order: 8
---

# Privacy policy

_Last updated: October 27, 2026_

This policy covers Spiel for Mac and Spiel Listen for iPhone.

## The short version

- Speech recognition runs on your device. **Spiel never sends your audio, your
  transcripts or anything you dictate to us or to anyone else.** There is no Spiel server.
- We collect no data. There is no account, no analytics, no advertising and no tracking.
- Your files are yours: they stay on your device until you delete them. They can leave the
  device in ways you control: your backups, iCloud syncing, a Shortcut you choose, or a file
  you share.

## What connects to the internet

None of these connections carry audio or anything you said.

**Mac app**

- **Speech model download** from Hugging Face, on first launch and whenever you switch to
  an engine whose model isn't downloaded yet (or Spiel falls back to one). The `spiel`
  command does the same the first time it needs a model.
- **Apple's speech engine**, if you use it: macOS downloads its model from Apple.
- **License activation** with Gumroad, when you enter a key, and a **license check** about
  once a week. Spiel sends your license key and Spiel's product ID.
- **Update checks** with GitHub, where Spiel's updates are published: automatically if you
  allowed it, or when you choose Check for Updates….

**iPhone app**

- **Speech model download** from Hugging Face, once.
- **Add location**, only when you turn it on for a meeting: the phone's location is sent to
  Apple's geocoding service to turn it into a place name (a place and town). If the calendar event has a location, Spiel uses that instead and doesn't
  look up where you are.

## What is stored on your device

Everything below is stored only on your device and kept until you delete it.

**Mac**

- **Listen transcripts** (and any screenshots) in `~/Documents/Spiel/Transcripts`.
- **Dictation History**, your last 50 dictations, in `~/Library/Application Support/Spiel`
  (unless you turn History off). Dictations taken while macOS Secure Input is on are never
  kept. **Copy Last Dictation** holds only your most recent dictation, in memory, until you
  quit.
- **Vocabulary** and **license** details in the same folder.
- **Speech models** in `~/Library/Application Support/FluidAudio/Models`.
- **Diagnostic log**, only if you turn it on (see below), in `~/Library/Logs/Spiel.log`.
- On the Mac, Spiel never saves audio.

**iPhone**

- **Transcripts** in Spiel's folder in the Files app.
- **Audio recordings**, only for meetings where you turn on **Keep audio**: an `.m4a` file
  saved next to the transcript.
- **Location**, only when you turn on Add location: a place name written into that
  meeting's transcript.
- **Calendar**: Spiel reads events happening now to offer the meeting's title, and the
  event's location if you turn on Add location. It writes only what you pick into the
  transcript, and never changes your calendar.
- **Speech model** in the app's own storage.

## Backups and iCloud

- **Mac:** if iCloud Drive's **Desktop & Documents Folders** option is on, your Documents
  folder, including Spiel's transcripts, syncs to iCloud. Time Machine and other backups
  include them too.
- **iPhone:** transcripts and kept audio are included in your iPhone backup (iCloud or your
  Mac). The speech model is left out of backups.

These copies are handled by Apple or your backup tool, not by Spiel.

## Shortcuts

If you choose a Shortcut to run when Listen stops, Spiel hands the transcript to it on your
device. What that Shortcut does with it is up to you: if it emails the transcript or sends
it to an online service, the transcript goes there.

## Diagnostic logging

Diagnostic Logging on the Mac is **off** unless you turn it on (Settings → General, or the
Help menu). **When it is on, the log includes the text you dictate.** It is stored only on
your Mac. Turn it off and delete `~/Library/Logs/Spiel.log` to remove it.

**Help → Send Diagnostics…** creates a zip with logs, app and system versions and permission
states. It withholds what you dictated, your transcripts and your vocabulary. It stays on
your Mac unless you send it yourself. If you attach it to a public GitHub issue, anyone can
read it.

The iPhone app has no diagnostic logging setting and no Send Diagnostics.

## Permissions, and how to turn them off

**Mac:** System Settings → Privacy & Security, then:

- **Microphone**, to hear you.
- **Accessibility**, to type into other apps.
- **Screen Recording**, only for screenshots in Listen.

Notifications are in System Settings → Notifications → Spiel.

**iPhone:** the iOS Settings app → Spiel:

- **Microphone**, to hear the meeting.
- **Calendars**, optional, to suggest a title.
- **Location**, optional, for Add location.

Turning a permission off stops Spiel using it. It doesn't delete anything already saved.

## Deleting your data

- **Mac transcripts:** delete the files in `~/Documents/Spiel/Transcripts` (menu → **Open
  Transcripts Folder**).
- **Mac History:** Settings → General → **Clear History**.
- **Everything on the Mac:** see [Uninstalling](updates-uninstall.md#uninstalling-the-mac-app).
- **iPhone transcripts and recordings:** swipe left on one in the transcripts list and tap
  Delete, or delete the app, which deletes all of them.

## Purchases

Purchases of the Mac app are handled by Gumroad, the merchant of record. Gumroad's
[privacy policy](https://gumroad.com/privacy) covers your payment and email details. Spiel
never sees your payment details.

## Children

Spiel is not directed at children. We collect no data from anyone, including children.

## Changes and questions

If this policy changes, the date at the top changes too. Questions: see
[Support](support.md).
