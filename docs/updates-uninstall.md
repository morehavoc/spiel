---
title: Updating and uninstalling
nav_order: 2.6
---

# Updating and uninstalling

## Updating the Mac app

Spiel updates itself. The second time you open it, it asks whether to check for updates
automatically, and you can check any time with **Check for Updates…** in the Spiel menu.
Updates come from Spiel's GitHub releases and are signed. Your settings, History,
Vocabulary, license and transcripts carry over.

If text stops appearing in other apps after an update, open System Settings → Privacy &
Security → Accessibility, remove Spiel with the **−** button, then add it again with **+**.

A build you compiled yourself checks for the official updates too. Installing one replaces
your build with the official one, which has the 14-day trial and needs a
[license](license.md) after that. To stay on your own build, don't install the update;
build the new version from source instead.

## Updating the iPhone app

While Spiel Listen is in testing, updates come through the TestFlight app.

## Uninstalling the Mac app

1. Quit Spiel (menu → **Quit Spiel**).
2. Drag **Spiel** from Applications to the Trash.

That removes the app. The files below stay on your Mac until you delete them. To find one,
choose **Go → Go to Folder…** in Finder and paste the path.

- Speech models, the biggest at about 700 MB:
  `~/Library/Application Support/FluidAudio/Models`. Other apps built on the same speech
  library may use this folder too.
- History, Vocabulary and your license: `~/Library/Application Support/Spiel`
- Settings, including your Shortcut choice and the trial start date:
  `~/Library/Preferences/com.morehavoc.spiel.plist`
- The diagnostic log, if you ever turned it on: `~/Library/Logs/Spiel.log` (and
  `Spiel.log.1` next to it, if the log grew big enough to roll over)
- The `spiel` command, if you installed it: `~/.local/bin/spiel` or
  `/usr/local/bin/spiel`. It's a link into the app and stops working once the app is gone.
- Your transcripts, in `~/Documents/Spiel/Transcripts`. Spiel never deletes these, so keep
  them or delete them yourself.

Uninstalling doesn't give back a license seat, and reinstalling doesn't restart the trial.
If you reinstall on the same Mac after deleting `~/Library/Application Support/Spiel`,
entering your key again uses a seat. See [Licensing](license.md#two-macs-per-key).

If you used Apple's speech engine, its model is managed by macOS.

## Uninstalling the iPhone app

Delete it the usual way: touch and hold the icon, then **Remove App** → **Delete App**.

**Deleting the app deletes its transcripts and recordings.** Copy them out first; see
[Your transcripts](iphone.md#your-transcripts).
