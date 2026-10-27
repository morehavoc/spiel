---
title: Listen (meetings)
nav_order: 3
---

# Listen: whole-meeting transcripts

Press **⌘⇧L** (or menu → Start Listening). A panel opens at the right edge of the screen with:

- an editable title, filled in from the frontmost window (Teams puts the meeting name there),
- a level meter, so you can see it is hearing you,
- a running counter (`Listening · 47:12 · 6,200 words`),
- the transcript, growing paragraph by paragraph.

It keeps going until you press **⌘⇧L** again or click **Stop**. **Pause** is a button.

## Where transcripts go

Each meeting is saved to **Documents → Spiel → Transcripts** as a Markdown file named
`<date> <time> <title>.md`. Spiel saves it every 30 seconds and at every paragraph, so a
crash late in a meeting loses at most the paragraph in progress. Renaming the meeting
renames the file.

The file starts with a header (title, start and end time, length, word count, microphone,
engine), then one paragraph per line with its time into the meeting, like
`[31:07] So the plan for Thursday is…`. Pauses and microphone changes appear as their own
lines, like `[paused 4 min]`.

When you stop, the panel shows a summary and **Copy** (plain text), **Open** (the file) and
**Done**. To have something happen automatically every time, see
[Run a Shortcut when Listen stops](shortcuts.md).

## Good to know

- Listen uses the microphone only. A good mic hears both sides of a call played through
  speakers; there is no system-audio capture and no speaker labels yet.
- Dictation (⌘⇧D) is refused while Listen is running: one microphone, one session.
- Listen writes text only. It never records audio to disk on the Mac.

## Screenshots

While Listen is recording or paused, press **⌃⌥⌘S** (or the camera button in the panel) to
capture the screen the mouse pointer is on. Spiel's own windows are left out of the shot.

- The image is saved in a folder next to the transcript, and the transcript gets an image
  line at that moment, so any Markdown viewer shows it inline.
- The first screenshot asks for **Screen Recording** permission (System Settings → Privacy &
  Security → Screen Recording). macOS may ask you to reopen Spiel afterwards.
- Change the key in Settings → General → Shortcuts → Screenshot.
