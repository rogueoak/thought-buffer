# Feedback 0008: post-device polish (duplicate-on-command, editing, resume, cheat sheet, recordings)

On-device testing produced a batch of fixes and refinements. Each item below is tracked to a
change on the `feedback/0008-post-device-polish` branch.

## 1. Duplicate paragraph after a Mira command (bug)

### What happened

Speaking one paragraph and pausing was fine; a second paragraph and pause was fine; then saying a
Mira command duplicated the second paragraph.

### Root cause

A single `SFSpeechRecognitionTask` accumulates the whole passage. `handlePartial`'s utterance-reset
detection (feedback 0007) commits a paragraph as soon as the recognizer starts a new utterance - so
the second paragraph is committed the moment the command begins. But the SAME task's FINAL
transcription can still lead with that just-committed paragraph (on device the recognizer's final
result is non-monotonic and restores earlier context), e.g. "P2 Mira read that back". `handleFinalized`
then splits that into pre-command text "P2" plus the command and commits "P2" a SECOND time.

### Fix

The service now tracks the text most recently committed via a reset within the current task
(`committedThisTask`) and strips it from the task-end transcription before committing the remainder
(`strippingCommittedPrefix`). It is tolerant of the recognizer's word revisions ("there is" ->
"there's") and of its own internal resets (nothing is stripped when the final result does NOT lead
with the committed text). Pure and unit-tested (`CommittedPrefixDedupTests`), including the exact
"paragraph then command" case.

## 2. Remove the on-record debug panel

The DEBUG on-screen trace was device-testing scaffolding. Removed from the record screen now that
capture is verified.

## 3. Cheat sheet of commands

A cheat-sheet button sits to the right of the Stop button on the record screen and opens a bottom
drawer listing the available voice commands (control word plus each command and what it does).

## 4. List screen (Thoughts)

- Title changed from "Stream" to "Thoughts".
- Removed the trailing `>` disclosure chevron on each note card; the card now fills the full row
  width and is tappable across its whole surface.

## 5. Keyboard editing of a note

The transcript is editable with the keyboard: tap into it to correct text. Editing is available when
capture is paused and on a saved note's page (not while words are actively streaming in, where a
moving cursor would fight the user).

## 6. Resume a note

A saved note's page offers Resume, which reopens the note into a recording session to continue where
it left off. New spoken content appends as text; the original recording is preserved but the resumed
portion is text-only on playback (it falls back to text-to-speech, the same as any edited paragraph).
Merging new audio into the finalized recording is deferred.

## 7. Seeing voice recordings

Recording is on by default (`AudioRetention.keep`). A recording plays from the "Play recording"
button on its note's own page whenever that note captured audio; there was previously no phone-side
way to browse recordings (only CarPlay had a list). Added a phone-side entry point so recordings are
discoverable, and verified audio attaches on save.

## Retest on device

- Speak two paragraphs with pauses, then a Mira command: the second paragraph is NOT duplicated.
- Tap the transcript and edit with the keyboard; open a saved note and tap Resume to keep dictating.
- Tap the cheat-sheet button by Stop to see the command list.
- The list title reads "Thoughts"; cards have no chevron and are tappable full-width.
- A note recorded with audio shows Play recording; recordings are reachable from the list.
