---
title: Getting started
nav_order: 2
---

# Getting started

## Before you start

- An Apple silicon Mac (M1 or later) with macOS 14 or later.
- About 700 MB of free disk space for the speech model.
- An internet connection for the first launch only.

## Install

1. Download **Spiel.dmg**, either from the link on your Gumroad receipt or directly from
   [GitHub](https://github.com/morehavoc/spiel/releases/latest/download/Spiel.dmg).
   Both are the same file, and the 14-day trial needs no purchase.
2. Open the downloaded **Spiel.dmg**.
3. Drag **Spiel** into the **Applications** folder.
4. Open Spiel from Applications. Spiel has no Dock icon. It lives in the menu bar at the
   top right of your screen, near the clock. The **Set up Spiel** window opens.

While the speech model is loading, the menu bar icon is a warning triangle. It turns into a
microphone when Spiel is ready.

## Set up Spiel

The setup window walks you through each step:

1. **Microphone**, so Spiel can hear you.
2. **Accessibility**, so Spiel can type into other apps. Turn Spiel on in System Settings →
   Privacy & Security → Accessibility. The step ticks itself within a second.
3. **Notifications**, so Spiel can tell you when something goes wrong.
4. **Screen Recording** (optional). Only needed for [screenshots in Listen](listen.md#screenshots).
5. **Speech model.** A one-time download, then a short "Preparing" step. The default model
   is about 615 MB, plus about 100 MB more for the vocabulary feature, so about 700 MB in
   all. After that Spiel works with no internet.
6. **Try it.** Shows the key to press.

You can reopen it any time from the menu: **Help → Setup…**.

## Dictate

1. Click into a text field, in any app.
2. Press **⌘⇧D** (hold Command and Shift, then press D) and talk.
3. Press **⌘⇧D** again. The text lands where your cursor is.

Prefer to hold the key while you talk? Settings → General → Shortcuts → **Dictation** →
**Hold to talk**.

## Settings

Menu bar icon → **Settings…**

- **Shortcuts:** change the Dictation, Listen and Screenshot keys, and choose
  press-to-start or hold-to-talk.
- **Microphone:** the system default, or a specific mic. If that mic is unplugged, Spiel
  uses the default and tells you.
- **Speech engine:**
  - **Parakeet Unified (English)**, the default. Best for English.
  - **Parakeet v3 (25 languages)**. Use it if you dictate in a language other than English.
  - **Apple (macOS 26 and later)**, Apple's built-in engine.

  Switching to an engine you haven't used before downloads its model (Parakeet v3 is about
  485 MB; macOS downloads Apple's). If an engine can't load, Spiel uses one of the others
  and says so in the menu.
- **When Listen stops:** [run one of your Shortcuts](shortcuts.md).
- **History:** keep your last 50 dictations, or turn it off. **Clear History** deletes them.
- **Open at Login** and **Diagnostic Logging** (see [Privacy](privacy.md#diagnostic-logging)).
- **Vocabulary** tab: names and jargon Spiel should spell your way. One per line: the
  spelling, a colon, then how it gets misheard, for example `ArcGIS: arc gis, arc g i s`.

## Your license

Spiel runs free for 14 days. To keep using it, buy a license on
[Gumroad](https://morehavoc.gumroad.com/l/spiel), then choose **Enter License Key…** from
the menu and paste the key from your receipt email. One license covers 2 Macs. Details,
including what happens when the trial ends: [Licensing](license.md).
