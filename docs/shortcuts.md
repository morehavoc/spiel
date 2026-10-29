---
title: Shortcuts
nav_order: 4
---

# Run a Shortcut when Listen stops

Spiel can hand every finished Listen transcript to one of your Shortcuts the moment you
stop. You can use it to file transcripts in Notes or Obsidian, email them to yourself, or
anything else Shortcuts can do. Your Shortcut decides where the transcript goes, so if it
emails it or sends it to an online service, that's where it ends up.

## 1. Make the Shortcut accept input

A Shortcut only receives what Spiel sends if it's set up to take input. New Shortcuts
aren't, and there's no "receive input" action to add; you turn it on in the Shortcut's
details.

### On the Mac

1. Open the Shortcuts app and double-click your Shortcut (or make a new one with **+**).
2. In the sidebar on the right, click the **ⓘ** (Shortcut Details) button.
3. Turn on **Use as Quick Action**. **Show in Share Sheet** works too.
4. A block appears at the top of the Shortcut: **Receive _Any_ input from _Quick Actions_**.
   You can click **Any** and choose **Files** to narrow it.
5. In the actions below, use the **Shortcut Input** variable wherever you want the
   transcript.

### On the iPhone

Start the Shortcut with Spiel's own action: search the action list for **Get Latest Spiel
Transcript** (Spiel Listen 0.3.5 or later) and put it first. It hands the rest of the Shortcut
the newest transcript as text, however long the meeting was. Nothing else needs turning on.

## 2. Pick it in Spiel

- Mac (Spiel 2.8 or later): Settings → General → **When Listen stops → Run Shortcut**, then
  pick it from the list. Choose **None** to turn it off.
- iPhone (Spiel Listen 0.3 or later): ⋯ menu → **Shortcut When Listen Stops**, then type the
  Shortcut's exact name, since iOS doesn't let apps list your Shortcuts. Tap **None** to turn
  it off.

## Example: save each transcript to Notes

On the Mac:

1. **Receive** input from Quick Actions, as in step 1.
2. **Get Text from** Shortcut Input.
3. **Create Note** with the Text.

On the iPhone:

1. **Get Latest Spiel Transcript**.
2. **Create Note** with the Latest Transcript.

## What the Shortcut receives

On the Mac the input is the transcript file. Spiel runs your Shortcut the way the
`shortcuts` command does, with the saved `.md` file as its input:

```
shortcuts run "Your Shortcut" --input-path "…/Transcripts/2026-10-27 1000 Weekly sync.md"
```

Actions that work on text, such as **Get Text from Input**, **Show Result** or
**Create Note**, read the file's contents. That's why it can look as if Spiel sent the
whole transcript as text. If you want the file's path or name, add **Get Details of Files**,
pass it Shortcut Input, and choose **File Path** (or **Name**).

On the iPhone, **Get Latest Spiel Transcript** gives you the transcript as text. iOS only lets
an app run a Shortcut by opening the Shortcuts app, so your phone switches to Shortcuts, runs
it, and comes back to Spiel. Spiel also passes shorter transcripts as Shortcut Input, so older
Shortcuts built that way keep working, but a transcript over about 100 KB (a meeting of two
hours or more) is too long to pass that way. The action works at any length, and Spiel never
puts the transcript on your clipboard.

## When it doesn't run

On the Mac, if the Shortcut fails or is missing, Spiel shows a notification with the
reason. A Shortcut still running after 10 minutes (one waiting for you to answer a question,
for example) is stopped. Nothing runs if the transcript couldn't be saved.

On the iPhone, it only runs if Spiel is on screen when Listen stops. Otherwise Spiel shows a
note instead.

## Advanced

### What's in the transcript

It's the same on both apps: a header block, then each paragraph with its time into the
meeting and a blank line between paragraphs.

```
---
app: Spiel
spiel_version: 2.8.1
kind: transcript
title: Weekly sync
started: 2026-10-27T10:00:04-07:00
ended: 2026-10-27T10:31:40-07:00
duration_s: 1896
words: 4210
source: microphone
input_device: MacBook Pro Microphone
engine: parakeet-unified-en-0.6b
---

[00:00] Okay, let's get started.

[00:07] First thing is the launch date...
```

A few differences:

- On the Mac, `engine` is `parakeet-unified-en-0.6b`, `parakeet-tdt-0.6b-v3` or
  `apple-speechanalyzer`. The iPhone always uses `parakeet-tdt-0.6b-v3`, and its
  `spiel_version` ends in `(iPhone)`.
- The iPhone adds `location:` when you turned on Add location, and `audio:` (the recording's
  file name) when you kept the audio.
- The Mac adds screenshot lines like `![Screenshot 12:34](…png)`, with the images in a
  folder next to the file.

A value that contains `:`, `#` or `"` is wrapped in double quotes, so a title like
`Q3: budget` is written `title: "Q3: budget"`.

### Pull out one field

Use **Match Text** with a pattern such as `title: (.*)` on the transcript text, then
**Get Group from Matched Text**. A quoted title keeps its quotes; remove them with
**Replace Text** if you need to.
