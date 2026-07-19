# Spec 0023 - Apple Watch app (quick-capture + browse)

## Motivation

Device feedback from Matthew (2026-07-19):

> The app should work on the watch.

Confirmed scope: **quick-capture + browse**. Record a voice note from the wrist;
the audio syncs to the phone, which transcribes and files it as a normal Note.
Browse and play recent notes on the watch. NOT full on-device dictation on the
watch.

## Depends on

Largest milestone; sequenced last (after search 0021 and iPad 0022). Reuses the
phone's Note storage and transcription. This spec is the plan; expect it to break
into several PRs (target setup, capture+sync, phone-side file transcription, browse/
play).

## Architecture

- **New watchOS app target** (added to project.yml / XcodeGen), paired with the iOS
  app. Canopy tokens shared where practical; watch-appropriate layouts.
- **WatchConnectivity** session on both sides:
  - Watch -> phone: `transferFile` the recorded `.m4a` (plus a small metadata
    payload: capture timestamp, optional folder hint). Reliable background transfer
    so a capture survives the watch app closing.
  - Phone -> watch: recent notes projection (title + short preview + duration + id)
    via `updateApplicationContext` / `transferUserInfo`, and on-demand audio file
    transfer for playback.

### 1. Quick capture (watch)

- A prominent Record control on the watch's main screen. Tap to record using the
  watch mic (AVAudioRecorder to `.m4a`); tap to stop. Simple, glanceable recording
  state; haptic on start/stop.
- On stop, enqueue the file for transfer to the phone. Show a lightweight "sent /
  will sync" state; the capture must not be lost if connectivity is momentarily
  unavailable (queued transfer).

### 2. Phone-side ingest + transcription (NEW capability)

- The phone receives the transferred audio and creates a Note from it: run
  FILE-BASED transcription (SpeechAnalyzer/SpeechTranscriber over the audio file, or
  SFSpeechURLRecognitionRequest as a fallback) to produce paragraphs + timings,
  derive the title (first sentence, spec 0009), attach the audio, and save via the
  existing store into the default location (or the folder hint).
- Reuse the existing paragraph/timing model and, when enabled, transcript refinement
  (spec 0016). Factor the file-transcription core so it is testable without the live
  mic path.
- Handle failure gracefully: keep the audio and file the note as audio-only (text
  can be regenerated later) rather than dropping the capture.

### 3. Browse + play (watch)

- A list of recent notes (from the phone projection): title + preview + duration.
- Tap a note to see its text and play its audio (transfer the audio file on demand;
  cache a few recent ones). Read-aloud/TTS optional if cheap.
- No editing/folder management on the watch in this milestone.

## Non-goals

- No on-device (watch) speech-to-text; transcription happens on the phone.
- No full note editing, folders, settings, or search on the watch.
- No standalone-watch (phone-absent) operation beyond capturing and queuing audio
  for later sync.
- No complications/Siri on watch in this milestone (possible follow-up).

## Acceptance

- The watch app builds/runs on a watch simulator, paired with the iOS app.
- Recording on the watch produces an audio file that transfers to the phone; the
  phone transcribes it and it appears as a normal Note (title, body, audio, timing)
  in the list.
- A capture made while the phone is unreachable syncs once connectivity returns
  (queued transfer), not lost.
- The watch shows recent notes and can play a note's audio.
- The phone-side file-transcription core is factored and unit-tested (maps a decoded
  transcript to paragraphs+timings) without requiring the live mic or a real watch.
- iOS app behavior is unchanged; the full iOS suite stays green.
