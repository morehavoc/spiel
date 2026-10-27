---
title: Updating and uninstalling
nav_order: 2.6
---

# Updating and uninstalling

## Updating the Mac app

The Gumroad build updates itself.

- The first time, Spiel asks once whether to check for updates automatically.
- To check now, choose **Check for Updates…** from the Spiel menu.
- Updates come from Spiel's GitHub releases and are signed, so your copy only installs
  genuine ones.
- Your settings, History, Vocabulary, license and transcripts carry over.

If text stops appearing in other apps after an update, turn Spiel off and on again in
System Settings → Privacy & Security → Accessibility.

A build you compiled yourself does not update; build the new version.

## Updating the iPhone app

While Spiel Listen is in testing, updates come through the TestFlight app.

## Uninstalling the Mac app

1. Quit Spiel (menu → **Quit Spiel**).
2. Drag **Spiel** from Applications to the Trash.

That removes the app. These stay on your Mac until you delete them. In Finder, choose
**Go → Go to Folder…** and paste each path:

- **Speech models** (the biggest, about 700 MB):
  `~/Library/Application Support/FluidAudio/Models`. Other apps built on the same speech
  library may use this folder too.
- **History, Vocabulary and license:** `~/Library/Application Support/Spiel`
- **Diagnostic log**, if you ever turned it on: `~/Library/Logs/Spiel.log`
- **The `spiel` command**, if you installed it: `~/.local/bin/spiel` (or
  `/usr/local/bin/spiel`). It is a link into the app and stops working once the app is gone.
- **Your transcripts:** `~/Documents/Spiel/Transcripts`. **Spiel never deletes these.**
  Keep them or delete them yourself.

Uninstalling does not give back a license seat, and reinstalling does not restart the trial.
If you reinstall on the same Mac after deleting `~/Library/Application Support/Spiel`,
entering your key again uses a seat. See [Licensing](license.md#two-macs-per-key).

Apple's speech engine model, if you used it, is managed by macOS.

## Uninstalling the iPhone app

Delete the app the usual way (touch and hold the icon → **Remove App** → **Delete App**).
**This deletes its transcripts and recordings.** Copy them out first: see
[Your transcripts](iphone.md#your-transcripts).
