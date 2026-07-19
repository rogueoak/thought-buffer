# 0014 - Natural text-to-speech voice

## Problem

The app's text-to-speech (Mira "read that back", and playback of text-only / resumed passages that have
no recording) uses `AVSpeechUtterance(string:)` with NO voice set, so it falls back to the system
DEFAULT compact voice - the robotic one. It sounds cheap next to the rest of the app and next to a
note played back in the user's own recorded voice.

## Outcome

- Spoken text uses the best-quality voice the user has installed for their language: a **premium**
  voice if present, else **enhanced**, else the default - so on a device with a modern voice installed
  it sounds close to Siri rather than robotic.
- No literal "Siri voice" (private to Apple) and no network - this is on-device `AVSpeechSynthesizer`.
- Graceful when only the compact voice exists (older device, nothing downloaded): it simply uses the
  default, exactly as today. Enhanced/premium voices are a one-time user download in
  Settings > Accessibility > Spoken Content > Voices.

## Scope

**In:** pick the best installed voice for the current language and set it on every utterance; a pure,
testable selection function. **Out:** a Settings UI to pick a specific voice, prompting the user to
download a voice, Personal Voice (iOS 17 own-voice model), and any rate/pitch retuning.

## Approach

- **`VoiceSelector`** - a pure enum with `bestVoiceIdentifier(from:languageCode:) -> String?` over a
  small `VoiceOption` value (identifier, language, quality). It prefers an exact language match
  (e.g. `en-US`) then a language-prefix match (`en`), and within the chosen pool picks the highest
  quality (premium > enhanced > default), tie-broken by identifier for determinism. Returns nil when
  no same-language voice exists, so the caller keeps the system default.
- **`SystemSpeaker`** resolves its preferred voice once (lazy) from
  `AVSpeechSynthesisVoice.speechVoices()` mapped to `VoiceOption`, using
  `AVSpeechSynthesisVoice.currentLanguageCode()`, and sets `utterance.voice` when one is found.
  Everything else (session handling, `onFinish`) is unchanged.

## Acceptance

- [ ] Given premium + enhanced + default voices for `en-US`, the selector returns the premium one.
- [ ] Given only enhanced + default, it returns the enhanced.
- [ ] Given no `en` voice at all, it returns nil (caller falls back to system default).
- [ ] An exact-language match is preferred over a same-prefix different-region voice.
- [ ] Selection is deterministic (stable tie-break) across equal-quality voices.
- [ ] Full suite green; the real spoken quality is device-verified (the picker is unit-tested).
