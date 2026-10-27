---
title: Listen (meetings)
nav_order: 3
---

# Listen: whole-meeting transcripts

**Listen uses the microphone only.** It does not capture your Mac's sound directly. If you
wear headphones on a call, Spiel hears you but not the other people. To capture both sides,
play the call through your speakers.

**Quick test:** before an important meeting, start Listen, play a short video through your
speakers, and stop. If the video's words are in the transcript, your setup works.

There are no speaker labels yet: the transcript does not say who said what.

## Start and stop

Press **⌘⇧L** (Command-Shift-L), or choose **Start Listening** from the menu. A panel opens
at the right edge of the screen with:

- an editable title, filled in from the frontmost window (Teams puts the meeting name there),
- a level meter, so you can see it is hearing you,
- a running counter (`Listening · 47:12 · 6,200 words`),
- the transcript, growing paragraph by paragraph.

It keeps going until you press **⌘⇧L** again or click **Stop**.

To pause, click **Pause** in the panel or choose **Pause Listening** from the menu. The
button becomes **Resume**.

Dictation doesn't work while Listen is running, since both use the microphone. Stop Listen
before you start dictating.

## Where transcripts go

Each meeting is saved to **Documents → Spiel → Transcripts**. To get there quickly, choose
**Open Transcripts Folder** from the menu.

- The file is named `<date> <time> <title>.md`, for example `2026-10-27 1000 Weekly sync.md`.
- Spiel saves it every 30 seconds and at every paragraph, so a crash late in a meeting loses
  at most the paragraph in progress.
- Renaming the meeting renames the file.
- Transcripts stay until you delete them. Spiel never deletes them.

## What the file is

A `.md` (Markdown) file is a plain text file. Any text editor opens it, including TextEdit.
Apps like Obsidian or Bear also show it formatted.

It starts with a short header (title, start and end time, length, word count, microphone,
engine). Then each paragraph starts with its time into the meeting, with a blank line
between paragraphs:

```
[31:07] So the plan for Thursday is…

[31:40] Right, and the venue is booked.
```

Pauses and microphone changes appear as their own lines, like `[paused 4 min]`. The full
header is shown in [What the Shortcut receives](shortcuts.md#what-the-shortcut-receives).

## When you stop

The panel shows a summary and:

- **Copy** puts the text on the clipboard, without the timestamps.
- **Open** opens the file.
- **Done** closes the panel.

To have something happen automatically every time, see
[Run a Shortcut when Listen stops](shortcuts.md).

Listen writes text only. On the Mac it never saves audio.

## Screenshots

While Listen is recording or paused, press **⌃⌥⌘S** (Control-Option-Command-S), click the
camera button in the panel, or choose **Take Screenshot** from the menu. Spiel captures the
screen the mouse pointer is on and leaves its own windows out of the shot.

- The image is saved in a folder next to the transcript, with the same name as the
  transcript. The transcript gets an image line at that moment, so Markdown apps show it
  inline.
- **Keep the folder with the transcript.** If you move or send the `.md` file, move or send
  its folder too, or the images won't show.
- The first screenshot asks for **Screen Recording** permission (System Settings → Privacy &
  Security → Screen Recording). macOS may ask you to reopen Spiel afterwards.
- If ⌃⌥⌘S is already used by Dictation or Listen, Spiel uses ⌃⌥⌘2 instead. Change the key in
  Settings → General → Shortcuts → Screenshot.
