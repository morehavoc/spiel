---
title: Shortcuts
nav_order: 4
---

# Run a Shortcut when Listen stops

Spiel can hand every finished Listen transcript to one of your Shortcuts, automatically,
the moment you stop. Use it to file transcripts in Notes or Obsidian, email them to
yourself, send them to an AI to summarize, or anything else Shortcuts can do. Spiel
itself sends nothing anywhere; your Shortcut decides what happens.

## 1. Make the Shortcut accept input

A Shortcut only receives what Spiel sends if it is set up to take input. New Shortcuts
are not, and there is no "receive input" action in the action list to add; you turn it
on in the Shortcut's details:

**On the Mac**
1. Open the Shortcuts app and double-click your Shortcut (or make a new one with **+**).
2. In the sidebar on the right, click the **ⓘ** (Shortcut Details) button.
3. Turn on **Use as Quick Action**. (**Show in Share Sheet** works too.)
4. A block appears at the top of the Shortcut: **Receive _Any_ input from _Quick Actions_**.
   Click **Any** and choose **Files** and **Text** if you want to narrow it.
5. In the actions below, use the **Shortcut Input** variable wherever you want the
   transcript (for example **Get Text from Shortcut Input**).

**On the iPhone**
1. Open the Shortcut, tap **ⓘ** at the bottom, and turn on **Show in Share Sheet**.
2. The **Receive _Any_ input from _Share Sheet_** block appears at the top; set it to **Text**.
3. Use **Shortcut Input** in your actions.

If the Shortcut runs but seems to get nothing, step 1 is usually what is missing.

## 2. Pick it in Spiel

- **Mac (Spiel 2.8 or later):** Settings → General → **When Listen stops → Run Shortcut**,
  and pick it from the list. Choose **None** to turn it off.
- **iPhone (Spiel Listen 0.3 or later):** ⋯ menu → **Shortcut When Listen Stops**, and type
  the Shortcut's exact name (iOS does not let apps list your Shortcuts).

## What the Shortcut receives

The saved transcript, exactly as Spiel writes it:

- **Mac:** the transcript **file** (`.md`) in your Transcripts folder.
- **iPhone:** the same Markdown as **text**. iOS only lets an app run a Shortcut by opening
  the Shortcuts app, so your phone switches to Shortcuts, runs it, and comes back to Spiel.
  A very long transcript (over about 100 KB) is passed through the clipboard instead, which
  replaces whatever you had copied.

The Markdown starts with a header block, then one line per paragraph with its time offset:

```
---
app: Spiel
kind: transcript
title: Weekly sync
started: 2026-10-27T10:00:04-07:00
ended: 2026-10-27T10:31:40-07:00
duration_s: 1896
words: 4210
source: microphone
input_device: MacBook Pro Microphone
engine: Parakeet
---

[00:00] Okay, let's get started.
[00:07] First thing is the launch date...
```

Other fields can appear: `location`, `audio` (when the meeting kept its recording), and on
the Mac, screenshot lines like `![Screenshot 12:34](…png)` (the images sit next to the file).
To pull out one field, use **Match Text** on a line such as `title: (.*)`.

## Example: save each transcript to Notes

1. **Receive** Files and Text from Quick Actions (step 1 above).
2. **Get Text from** Shortcut Input.
3. **Create Note** with the Text.

## When it does not run

- **Mac:** if the Shortcut fails or is missing, Spiel shows a notification with the reason.
  A Shortcut that is still running after 10 minutes (for example, one waiting for you to
  answer a question) is stopped. Nothing runs if the transcript could not be saved.
- **iPhone:** it only runs when Spiel is on screen when Listen stops; if not, Spiel shows a
  note instead.
