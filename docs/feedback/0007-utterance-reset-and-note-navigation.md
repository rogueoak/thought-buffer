# Feedback 0007: on-device utterance reset, and land on the saved note

## What happened

On-device testing (screen recording) showed dictation losing text across a pause: "Hey how's it
going" was replaced by "Yeah things are going pretty good", and only the second survived. The
DEBUG on-screen trace showed the live partial jumping from the first phrase to the second with NO
`final:` line in between.

## Root cause

A single `SFSpeechRecognitionTask` does not always end on a pause. On device, after a silence the
recognizer often begins a NEW utterance's transcription WITHIN the same task, so
`bestTranscription` resets to the new phrase and never fires a task end. The prior fix (feedback
0006) committed on task end, which never came, so the pre-pause words - held only in the tracked
partial - were overwritten and lost.

## Fix

Detect the reset at the PARTIAL level. `SpeechDictationService.isReset(previous:current:)` returns
true when the new partial is not a continuation of the last one (it does not reproduce all-but-the
last word of the previous partial at its start). When a partial is a reset, the service commits the
previous partial as its own paragraph (a `.finalizedSegment`) before adopting the new text, so each
utterance separated by a pause becomes its own paragraph and nothing is lost. Pure and unit-tested
(`UtteranceResetTests`), including the exact phrase pair from the recording.

## Also

When a recording stops, the app now navigates to the saved note's detail page (pushes it on the
stream's `NavigationStack`) instead of returning to the list, so the user lands on what they just
recorded.

## Retest on device

- Speak, pause several seconds, keep talking: all prior text stays (as separate paragraphs).
- Read-back ("<control word> read that back") now has committed text to read.
- Stopping a recording opens that note's page.
