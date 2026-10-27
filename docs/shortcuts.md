---
title: Shortcuts
nav_order: 4
---

# Run a Shortcut when Listen stops

Spiel can hand every finished Listen transcript to one of your Shortcuts, automatically,
the moment you stop. Use it to file transcripts in Notes or Obsidian, email them to
yourself, or anything else Shortcuts can do.

Spiel itself sends nothing anywhere. Your Shortcut decides what happens, so if it emails the
transcript or sends it to an online service, the transcript goes there.

## 1. Make the Shortcut accept input

A Shortcut only receives what Spiel sends if it is set up to take input. New Shortcuts
are not, and there is no "receive input" action to add. You turn it on in the Shortcut's
details.

**On the Mac**
1. Open the Shortcuts app and double-click your Shortcut (or make a new one with **+**).
2. In the sidebar on the right, click the **ⓘ** (Shortcut Details) button.
3. Turn on **Use as Quick Action**. (**Show in Share Sheet** works too.)
4. A block appears at the top of the Shortcut: **Receive _Any_ input from _Quick Actions_**.
   Click **Any** and choose **Files** if you want to narrow it.
5. In the actions below, use the **Shortcut Input** variable wherever you want the
   transcript.

**On the iPhone**
1. Open the Shortcut, tap **ⓘ** at the bottom, and turn on **Show in Share Sheet**.
2. The **Receive _Any_ input from _Share Sheet_** block appears at the top. Set it to **Text**.
3. Use **Shortcut Input** in your actions.

If the Shortcut runs but seems to get nothing, step 1 is usually what is missing.

## 2. Pick it in Spiel

- **Mac (Spiel 2.8 or later):** Settings → General → **When Listen stops → Run Shortcut**,
  and pick it from the list. Choose **None** to turn it off.
- **iPhone (Spiel Listen 0.3 or later):** ⋯ menu → **Shortcut When Listen Stops**, and type
  the Shortcut's exact name (iOS does not let apps list your Shortcuts). Tap **None** to
  turn it off.

## What the Shortcut receives

**On the Mac, the input is the transcript file.** Spiel runs your Shortcut the way the
`shortcuts` command does, with the saved `.md` file as its input:

```
shortcuts run "Your Shortcut" --input-path "…/Transcripts/2026-10-27 1000 Weekly sync.md"
```

- Actions that work on text, such as **Get Text from Input**, **Show Result** or
  **Create Note**, read the file's contents. That is why it can look as if Spiel sent the
  whole transcript as text.
- **To get the file's path or name instead,** add **Get Details of Files**, pass it Shortcut
  Input, and choose **File Path** (or **Name**).

**On the iPhone, the input is the transcript as text.** There is no file. iOS only lets an
app run a Shortcut by opening the Shortcuts app, so your phone switches to Shortcuts, runs
it, and comes back to Spiel. A very long transcript (over about 100 KB) is passed through
the clipboard instead, which replaces whatever you had copied.

## What's in the transcript

The same on both. A header block, then each paragraph with its time into the meeting, with
a blank line between paragraphs:

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

- `engine` is `parakeet-unified-en-0.6b`, `parakeet-tdt-0.6b-v3` or `apple-speechanalyzer`
  on the Mac. The iPhone always uses `parakeet-tdt-0.6b-v3`, and its `spiel_version` ends
  in `(iPhone)`.
- **iPhone only:** `location:` (when you turned on Add location) and `audio:` (the name of
  the recording, when you kept the audio).
- **Mac only:** screenshot lines like `![Screenshot 12:34](…png)`. The images sit in a
  folder next to the file.
- A value that contains `:`, `#` or `"` (a title like `Q3: budget`, say) is wrapped in
  double quotes: `title: "Q3: budget"`.

### Advanced: pull out one field

Use **Match Text** with a pattern such as `title: (.*)` on the transcript text, then
**Get Group from Matched Text**. A quoted title keeps its quotes, so remove them with
**Replace Text** if you need to.

## Example: save each transcript to Notes

1. **Receive** input from Quick Actions (Mac) or the Share Sheet (iPhone), as in step 1.
2. **Get Text from** Shortcut Input.
3. **Create Note** with the Text.

## When it does not run

- **Mac:** if the Shortcut fails or is missing, Spiel shows a notification with the reason.
  A Shortcut that is still running after 10 minutes (for example, one waiting for you to
  answer a question) is stopped. Nothing runs if the transcript could not be saved.
- **iPhone:** it only runs when Spiel is on screen when Listen stops. If not, Spiel shows a
  note instead.
