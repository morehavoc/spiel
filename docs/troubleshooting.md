---
title: Troubleshooting
nav_order: 7
---

# Troubleshooting

### The menu bar icon is a warning triangle

Spiel is still loading the speech model, or something needs attention. Click the icon: the
menu says what is wrong, for example **Loading speech model…** or a shortcut that isn't
working.

### The shortcut does nothing

Another app may own that key combination. Spiel shows a warning icon in the menu bar and
the reason in the menu. Pick another key in Settings → General → Shortcuts. For Dictation,
you can also choose **Use F5 Instead** from the menu. On many Mac keyboards you press
**Fn-F5**.

### Text doesn't appear in the app I'm typing in

Check System Settings → Privacy & Security → Accessibility and make sure Spiel is on. If
Spiel was just updated, turn it off and on again.

To get the text back: **Copy Last Dictation** in the menu has your most recent dictation
until you quit Spiel, and **History…** keeps your last 50, unless you turned History off in
Settings.

### Nothing is typed in a password field

When macOS Secure Input is on (a password field, or an app that holds it on), the menu says
so. Spiel pastes anyway and leaves the text on the clipboard for about 90 seconds, so if it
didn't land you can press **⌘V**. A dictation taken while Secure Input is on is not saved to
History or the log, and Copy Last Dictation doesn't have it.

### I can't dictate while Listen is running

Expected. Both use the microphone. Stop Listen before you start dictating.

### It hears the wrong word for a name or term

Add it in Settings → **Vocabulary**: the spelling, a colon, then how it gets misheard.

### The Listen meter barely moves

Check the input in Settings → Microphone and your Mac's input volume. The meter adjusts to
quiet mics; if it stays flat, the mic may be the wrong one.

### Listen only has my side of the call

Listen hears the microphone only. With headphones, the other people never reach it. See
[Listen](listen.md).

### The model download failed

Check your connection and press **Retry** in the setup window (Help → Setup…).

### My Shortcut runs but gets nothing

Turn on input for the Shortcut: see
[Run a Shortcut when Listen stops](shortcuts.md#1-make-the-shortcut-accept-input).

### My license key won't activate

See [Licensing](license.md#if-activation-fails).

### iPhone: Spiel says microphone, calendar or location access is off

Open the iOS **Settings** app, find Spiel (it may be listed as **Spiel Listen**), and turn
it on.

Still stuck? See [Support](support.md).
