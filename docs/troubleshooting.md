---
title: Troubleshooting
nav_order: 7
---

# Troubleshooting

### The menu bar icon is a warning triangle

Spiel is still loading the speech model, or something needs attention. Click the icon and
the menu says what's wrong, for example **Loading speech model…** or a shortcut that isn't
working.

### The shortcut does nothing

Another app may already use that shortcut. Spiel shows a warning icon in the menu bar and
the reason in the menu. Pick another key in Settings → General → Shortcuts. For Dictation,
you can also choose **Use F5 Instead** from the menu; on many Mac keyboards that means
pressing **Fn-F5**.

### Text doesn't appear in the app I'm typing in

Open System Settings → Privacy & Security → Accessibility and check that Spiel is on. If it
is on and text still doesn't appear (this often happens after an update), remove Spiel with
the **−** button, then add it again with **+**.

To get the text back, **Copy Last Dictation** in the menu has your most recent dictation
until you quit Spiel, and **History…** keeps your last 50 unless you turned History off.

### Dictating into a password field

When macOS Secure Input is on (in a password field, or because an app holds it on), the menu
says so. Spiel pastes anyway and leaves the text on the clipboard for about 90 seconds, so if
it didn't land you can press **⌘V**. This replaces whatever you had copied, and Spiel doesn't
put it back. A dictation taken while Secure Input is on isn't saved to History or the log,
and Copy Last Dictation doesn't have it.

### I can't dictate while Listen is running

Both use the microphone, so stop Listen before you start dictating.

### It hears the wrong word for a name or term

Add it in Settings → **Vocabulary**: the spelling, a colon, then how it gets misheard.

### The Listen meter barely moves

Check the input in Settings → Microphone and your Mac's input volume. The meter adjusts to
quiet mics, so if it stays flat, it may be listening to the wrong mic.

### Listen only has my side of the call

Listen only hears the microphone, so with headphones on, the other people never reach it.
See [Listen](listen.md).

### The screenshot key is ⌃⌥⌘2

That happens when ⌃⌥⌘S is already used by Dictation or Listen. Change it in Settings →
General → Shortcuts → **Screenshot**.

### The model download failed

Check your connection and press **Retry** in the setup window (Help → Setup…).

### My Shortcut runs but gets nothing

Turn on input for the Shortcut; see
[Run a Shortcut when Listen stops](shortcuts.md#1-make-the-shortcut-accept-input).

### My license key won't activate

See [Licensing](license.md#if-activation-fails).

### iPhone: Spiel says microphone, calendar or location access is off

Open the iOS **Settings** app, find **Spiel Listen**, and turn it on.

For more help, see [Support](support.md).
