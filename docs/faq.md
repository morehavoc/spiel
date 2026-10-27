---
title: FAQ
nav_order: 7.5
---

# Frequently asked questions

### Which languages does it understand?

- **Parakeet Unified (English)**, the Mac default: English only.
- **Parakeet v3 (25 languages)**: switch to it in Settings → General → Speech engine. The
  iPhone app always uses this one.
- **Apple (macOS 26 and later)**: Apple's built-in engine.

### Which engine should I pick?

Start with the default. If you dictate in a language other than English, switch to
Parakeet v3. Switching downloads that engine's model the first time.

### Does it add punctuation?

Yes. The speech model adds punctuation and capital letters as it transcribes.

### It keeps getting a name wrong. Can I fix that?

On the Mac, add it in Settings → **Vocabulary**: the spelling you want, a colon, then how it
gets misheard (`ArcGIS: arc gis, arc g i s`). It applies to every engine, to dictation,
Listen and the `spiel` command. The iPhone app has no Vocabulary editor.

### Does it work offline?

Yes, once the speech model is downloaded. The internet is used only for the things listed in
the [privacy policy](privacy.md#what-connects-to-the-internet).

### Where is my dictation history, and how do I delete it?

Menu → **History…** shows your last 50 dictations, searchable. Settings → General →
History has **Clear History** and a switch to stop keeping them. Turning it off keeps the
existing entries until you clear them.

### Can it record system audio, or tell speakers apart?

Not yet. Listen hears the microphone only, and there are no speaker labels. See
[Listen](listen.md).

### Does the iPhone app sync with the Mac?

No. Move transcripts with Share, the Files app, or Finder. See
[Your transcripts](iphone.md#your-transcripts).

### How much disk space does it use?

- **Mac:** about 700 MB for the default speech model. Parakeet v3 adds about 485 MB if you
  switch to it. Transcripts are small text files.
- **iPhone:** about 500 MB for the speech model, plus about 14 MB an hour for meetings where
  you keep the audio.
