---
title: Listen (meetings)
nav_order: 3
---

# Listen: whole-meeting transcripts

Listen records a meeting or a talk and writes a transcript as it goes, with a timestamp on
each paragraph.

**Listen only hears the microphone.** It doesn't capture your Mac's sound directly, so if
you wear headphones on a call, Spiel hears you and not the other people. To get both sides,
play the call through your speakers. Before an important meeting it's worth a quick test:
start Listen, play a short video through your speakers, and stop. If the video's words are
in the transcript, your setup works.

There are no speaker labels yet, so the transcript doesn't say who said what.

## Start and stop

Press **⌘⇧L** (Command-Shift-L), or choose **Start Listening** from the menu. A panel opens
at the right edge of the screen with an editable title (filled in from the frontmost
window; Teams puts the meeting name there), a level meter so you can see it's hearing you,
a running counter like `Listening · 47:12 · 6,200 words`, and the transcript itself,
growing paragraph by paragraph.

It keeps going until you press **⌘⇧L** again or click **Stop**. To pause, click **Pause** in
the panel or choose **Pause Listening** from the menu; the button becomes **Resume**.

Dictation doesn't work while Listen is running, because both use the microphone.

## When you stop

The panel shows a summary with three buttons. **Copy** puts the text on the clipboard
without the timestamps, **Open** opens the file, and **Done** closes the panel.

To have something happen automatically every time, see
[Run a Shortcut when Listen stops](shortcuts.md).

## Where transcripts go

Each meeting is saved as a text file in **Documents → Spiel → Transcripts**, named with the
date, time and title, like `2026-10-27 1000 Weekly sync.md`. Choose **Open Transcripts
Folder** from the menu to get there. If you rename the meeting, the file is renamed too.
Spiel saves as it goes and keeps transcripts until you delete them. It doesn't save the
audio.

The `.md` means Markdown, which is plain text. Any text editor opens it, including
TextEdit, and apps like Obsidian or Bear show it formatted. The file starts with a short
header (title, times, length, word count, microphone and engine), and each paragraph
starts with its time into the meeting:

```
[31:07] So the plan for Thursday is…

[31:40] Right, and the venue is booked.
```

Pauses and microphone changes get their own lines, like `[paused 4 min]`. The full header is
in [What's in the transcript](shortcuts.md#whats-in-the-transcript).

## Screenshots

While Listen is recording or paused, press **⌃⌥⌘S** (Control-Option-Command-S), click the
camera button in the panel, or choose **Take Screenshot** from the menu. Spiel captures the
screen your mouse pointer is on and leaves its own windows out of the shot.

The image goes in a folder next to the transcript with the same name, and the transcript
gets an image line at that moment, so Markdown apps show it inline. If you move or send the
`.md` file, move or send that folder with it, or the images won't show.

The first screenshot asks for Screen Recording permission (System Settings → Privacy &
Security → Screen Recording), and macOS may ask you to reopen Spiel afterwards.

### Advanced

- Spiel writes the file every 30 seconds and at the end of every paragraph, so a crash late
  in a meeting loses at most the paragraph in progress.
- If ⌃⌥⌘S is already taken by Dictation or Listen, the screenshot key becomes ⌃⌥⌘2. You
  can change it in Settings → General → Shortcuts → **Screenshot**.
