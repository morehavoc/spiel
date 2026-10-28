---
title: Privacy policy
nav_order: 8
---

# Privacy policy

_Last updated: October 27, 2026_

This policy covers Spiel for Mac and Spiel Listen for iPhone, both made by me, Christopher
Moravec.

## The short version

Speech recognition runs on your device. Your audio, your transcripts and what you dictate
are never sent to me or to anyone else, and there is no Spiel server. I don't collect any
data. There's no account to sign up for, and Spiel has no analytics, ads or tracking.

What Spiel saves stays on your device, and how long each thing is kept is listed below. It
leaves the device only in ways you control, such as your backups, iCloud, a Shortcut you
choose, or a file you share.

## What connects to the internet

None of these connections carry audio or anything you said. As with any internet
connection, the service on the other end sees your IP address.

### Mac app

- Speech model download from Hugging Face, on first launch and when you switch to an
  engine whose model isn't on your Mac yet (or Spiel falls back to one). The `spiel` command
  does the same the first time it needs a model.
- If you use Apple's speech engine, macOS downloads its model from Apple.
- License activation with Gumroad when you enter a key, and a license check about once a
  week. Spiel sends your license key and Spiel's product ID.
- Update checks with GitHub, where Spiel's updates are published. They happen automatically
  if you allowed it, or when you choose **Check for Updates…**.

### iPhone app

- Speech model download from Hugging Face, once.
- Add location. With the **Add location** switch on, when you tap **Start listening** and
  the calendar event didn't name a place, Spiel gets your phone's location and sends it to
  Apple's geocoding service to turn it into a place name (a place and town). Nothing is
  looked up before you start, or if you cancel. The switch stays on for later meetings
  until you turn it off.

## What is stored on your device

### Mac

- Listen transcripts, and any screenshots you take during Listen, in
  `~/Documents/Spiel/Transcripts`. Kept until you delete them.
- Dictation History in `~/Library/Application Support/Spiel`, unless you turn History off.
  It holds your last 50 dictations; older ones are dropped as new ones come in. Turning
  History off stops new entries but keeps the existing ones until you clear them.
  Dictations taken while macOS Secure Input is on are never kept.
- Copy Last Dictation keeps only your most recent dictation, in memory, until you quit
  Spiel.
- When Secure Input is on, the dictated text is put on the clipboard and cleared after about
  90 seconds if it's still there.
- Your vocabulary list, in the same folder, until you delete it.
- License details (the key, when it was activated and the trial start date) in
  `~/Library/Application Support/Spiel/license.json`, and settings (including your Shortcut
  choice and the trial start date) in `~/Library/Preferences/com.morehavoc.spiel.plist`.
  Kept until you delete them.
- Speech models in `~/Library/Application Support/FluidAudio/Models`, until you delete them.
- A diagnostic log, only if you turn it on; see [Diagnostic logging](#diagnostic-logging).

The Mac app never saves audio.

### iPhone

- Transcripts in Spiel Listen's folder in the Files app, until you delete them or the app.
- Audio recordings, only for meetings where you turn on **Keep audio**: an `.m4a` file next
  to the transcript, kept until you delete that transcript or the app.
- Location, only with Add location on: the calendar event's location if it has one and you
  chose that meeting, otherwise the place name from Apple. If the place name can't be found,
  the latitude and longitude are written instead. It's stored in that meeting's transcript
  and nowhere else.
- Calendar: Spiel reads events from 15 minutes ago to 30 minutes ahead to offer a meeting's
  title (and its location, with Add location on). It writes only what you pick into the
  transcript and never changes your calendar.
- The name of the Shortcut you chose, and your Add location and Keep audio switches, in the
  app's settings.
- The speech model, in the app's own storage, until you delete the app.

## Backups and iCloud

On the Mac, if iCloud Drive's **Desktop & Documents Folders** option is on, your Documents
folder (Spiel's transcripts included) syncs to iCloud. Time Machine and other backups include
them too.

On the iPhone, transcripts and kept audio are part of your iPhone backup (iCloud or your
Mac). The speech model is left out of backups.

Apple or your backup tool handles those copies.

## Shortcuts

If you choose a Shortcut to run when Listen stops, Spiel hands the transcript to it on your
device. What happens next is up to that Shortcut: if it emails the transcript or sends it
to an online service, the transcript goes there.

## Diagnostic logging

Diagnostic Logging on the Mac is off unless you turn it on (Settings → General, or the Help
menu). **When it's on, the log includes the text you dictate.** It's stored only on your
Mac, in `~/Library/Logs/Spiel.log`. When the log reaches 5 MB it's moved to `Spiel.log.1`
and a new one starts, so at most the current log and one older one are kept. Turn logging
off and delete both files to remove it.

**Help → Send Diagnostics…** makes a zip with the end of the diagnostic log (if there is one), app and system versions and
permission states, and saves it where you choose (the Desktop by default). It leaves out
what you dictated, your transcripts, your history and your vocabulary. It stays on your Mac
unless you send it to me.

The iPhone app has no diagnostic logging and no Send Diagnostics.

## Permissions

### Mac

In System Settings → Privacy & Security:

- Microphone, to hear you.
- Accessibility, to type into other apps.
- Screen Recording, only for screenshots in Listen.
- macOS may also ask for access to your Documents folder, where transcripts are saved.

Notifications are in System Settings → Notifications → Spiel.

### iPhone

In the iOS Settings app → **Spiel Listen**:

- Microphone, to hear the meeting.
- Calendars (optional), to suggest a title.
- Location (optional, while using the app), for Add location.

Turning a permission off stops Spiel using it. It doesn't delete anything already saved.

## Deleting your data

- Mac History: Settings → General → **Clear History**.
- Mac transcripts: menu → **Open Transcripts Folder**, then delete the files.
- Everything else on the Mac: see [Uninstalling the Mac app](updates-uninstall.md#uninstalling-the-mac-app).
- iPhone transcripts and recordings: see [Your transcripts](iphone.md#your-transcripts).
  Deleting the app deletes all of them.

## Purchases

Gumroad handles purchases of the Mac app, and its
[privacy policy](https://gumroad.com/privacy) covers your payment and email details. The app
never sees your payment details.

## Children

Spiel isn't made for children, and it doesn't collect data from anyone, children included.

## Contact

Questions about this policy go to
[spiel@christophermoravec.com](mailto:spiel@christophermoravec.com).
