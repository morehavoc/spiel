---
title: Getting started
nav_order: 2
---

# Getting started

You need an Apple silicon Mac (M1 or later) with macOS 14 or later, about 700 MB of free
disk space for the speech model, and an internet connection the first time you open Spiel.

## Install

1. Download **Spiel.dmg**, either from the link on your Gumroad receipt or from
   [GitHub](https://github.com/morehavoc/spiel/releases/latest/download/Spiel.dmg). They're
   the same file, and you don't need to buy anything to start the 14-day trial.
2. Open **Spiel.dmg** and drag **Spiel** into the **Applications** folder.
3. Open Spiel from Applications.

Spiel has no Dock icon. It lives in the menu bar at the top right of your screen, near the
clock, and the **Set up Spiel** window opens on first launch. While the speech model loads,
the menu bar icon is a warning triangle; it turns into a microphone when Spiel is ready.

## Set up Spiel

The setup window takes you through each step:

1. **Microphone**, so Spiel can hear you.
2. **Accessibility**, so Spiel can type into other apps. Turn Spiel on in System Settings →
   Privacy & Security → Accessibility.
3. **Notifications**, so Spiel can tell you when something goes wrong.
4. **Screen Recording**, which is optional and only used for
   [screenshots in Listen](listen.md#screenshots).
5. **Speech model**, a one-time download of about 700 MB followed by a short "Preparing"
   step. After that Spiel works without the internet.
6. **Try it**, which shows you the key to press.

You can open it again any time from the menu: **Help → Setup…**.

The first time you save a Listen transcript, macOS may ask whether Spiel can use your
Documents folder. That's where transcripts go.

## Dictate

1. Click into a text field in any app.
2. Press **⌘⇧D** (hold Command and Shift, then press D) and talk.
3. Press **⌘⇧D** again, and the text lands where your cursor is.

To hold the key while you talk instead, go to Settings → General → Shortcuts →
**Dictation** and pick **Hold to talk**.

## Settings

Open them from the menu bar icon → **Settings…**. The ones most people touch:

- **Shortcuts** for the Dictation, Listen and Screenshot keys.
- **Microphone**, either the system default or a specific mic. If that mic is unplugged,
  Spiel falls back to the default and tells you.
- **When Listen stops**, to [run one of your Shortcuts](shortcuts.md).
- **History**, which keeps your last 50 dictations. **Clear History** deletes them, and you
  can turn History off.
- **Open at Login**.

### Advanced settings

#### Speech engine

There are three:

- **Parakeet Unified (English)** is the default and the best choice for English.
- **Parakeet v3 (25 languages)** is for dictating in other languages. Its model is about
  485 MB more.
- **Apple (macOS 26 and later)** uses Apple's built-in engine (US English), and macOS
  downloads its model.

Switching to an engine you haven't used before downloads its model. If an engine can't
load, Spiel uses one of the others and says so in the menu.

#### Vocabulary

The Vocabulary tab is for names and jargon you want spelled your way, one
per line: the spelling, a colon, then how it gets misheard, for example
`ArcGIS: arc gis, arc g i s`. Spiel also fixes the spelling of a short built-in list of
terms (ArcGIS, GeoJSON, Xcode, macOS and a few others). The vocabulary feature accounts for
about 100 MB of the first download.

#### Diagnostic Logging

This writes a log to help track down problems. It includes the text you
dictate, so leave it off unless you need it; see [Privacy](privacy.md#diagnostic-logging).

## Your license

Spiel runs free for 14 days. To keep using it, buy a license on
[Gumroad](https://morehavoc.gumroad.com/l/spiel), choose **Enter License Key…** from the
menu, and paste the key from your receipt email. One license covers 2 Macs. What happens
when the trial ends, and the rest of the details, are on [Licensing](license.md).
