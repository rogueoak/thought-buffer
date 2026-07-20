# Feedback 0031 - Recording fails to start ("Something went wrong starting the recorder")

## Symptom

Device report (2026-07-19): with the microphone permission granted, tapping Record
fails every time with "Something went wrong starting the recorder. Please try again."
Recording was completely broken.

## Root cause

A regression from capture-pipeline feedback 0026 (PR #47). To address a transcription
QUALITY concern, `SpeechAnalyzerService.configureSession()` changed the audio session
mode from `.measurement` to `.spokenAudio`:

    try session.setCategory(.record, mode: .spokenAudio, options: [.duckOthers])

`.spokenAudio` is a PLAYBACK mode (continuous long-form spoken content, e.g. podcasts /
audiobooks - it pauses when another app plays a short prompt). It is NOT a valid mode
for a `.record` input session. Setting an incompatible mode makes `setCategory` THROW,
which the capture start maps to `SpeechCaptureError.engineFailure` and the view model
renders as the generic "something went wrong starting the recorder" copy
(`DictationViewModel.DeniedReason.engineFailure`).

Because the `.spokenAudio` change threw at start, the "quality fix" never actually ran -
recording was broken by it, not improved.

The Simulator does not exercise the real `AVAudioSession` the way hardware does, so the
CI suite stayed green and the bug was device-only. It also slipped through persona
review, which accepted the (incorrect) claim that `.spokenAudio` is Apple's dictation
mode.

## Fix

Restore `.measurement` - the last known-working value and Apple's documented mode for
speech recognition (its own Speech-framework dictation samples use `.record` +
`.measurement`):

    try session.setCategory(.record, mode: .measurement, options: [.duckOthers])

`.duckOthers` is kept. The `transcriptionOptions: []` change from feedback 0026 (drop
the redacting `.etiquetteReplacements`) is correct and stays.

## Open item

The original transcription-QUALITY concern that motivated the mode change is NOT
re-addressed here (restoring function comes first). If dictation quality is genuinely
poor with `.measurement`, it must be investigated and validated ON DEVICE - not by
swapping session modes blind, which is what caused this regression.

## Acceptance

- On device, tapping Record starts capture and transcribes (no "something went wrong").
- Full suite green (696 tests).
