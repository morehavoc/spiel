---
title: FAQ
nav_order: 7.5
---

# Frequently asked questions

### Which languages does it understand, and which engine should I pick?

Start with the Mac's default, **Parakeet Unified (English)**, which is English only. If you
dictate in another language, switch to **Parakeet v3 (25 languages)** in Settings → General
→ Speech engine; it downloads its model the first time. **Apple (macOS 26 and later)** uses
Apple's built-in engine, set to US English.

Parakeet v3 understands Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish,
French, German, Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese,
Romanian, Russian, Slovak, Slovenian, Spanish, Swedish and Ukrainian.

The iPhone app always uses Parakeet v3.

### Does it add punctuation?

Yes. The speech model adds punctuation and capital letters as it transcribes.

### It keeps getting a name wrong. Can I fix that?

On the Mac, add it in Settings → **Vocabulary**: the spelling you want, a colon, then how it
gets misheard (`ArcGIS: arc gis, arc g i s`). It applies to every engine, and to dictation,
Listen and the `spiel` command.

The iPhone app has no Vocabulary editor. Both apps also fix the spelling of a short
built-in list of terms (ArcGIS, GeoJSON, Xcode, macOS and a few others).

### Does it work offline?

Yes, once the speech model is downloaded. The few things that do use the internet are
listed in the [privacy policy](privacy.md#what-connects-to-the-internet).

### Where is my dictation history, and how do I delete it?

Menu → **History…** shows your last 50 dictations, searchable. Settings → General → History
has **Clear History** and a switch to stop keeping them. Turning it off keeps the existing
entries until you clear them.

### Can it record system audio, or tell speakers apart?

Not yet. Listen only hears the microphone, and there are no speaker labels. See
[Listen](listen.md).

### Does the iPhone app sync with the Mac?

No. Move transcripts with Share, the Files app or Finder; see
[Your transcripts](iphone.md#your-transcripts).

### How much disk space does it use?

On the Mac, about 700 MB for the default speech model, plus about 485 MB if you switch to
Parakeet v3. Transcripts are small text files.

On the iPhone, about 500 MB for the speech model, plus about 14 MB an hour for meetings where
you keep the audio.
