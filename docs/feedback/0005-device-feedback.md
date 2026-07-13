# 0005 - On-device testing feedback

Seven issues found during real on-device testing (live mic, real notes). Fixes landed together
on branch `feat/device-feedback-fixes`. Several can only be FULLY confirmed on a physical device;
those are flagged under "Needs device retest".

## Symptom

1. **Record button overlaps the empty-state help text.** On first launch (no notes) the floating
   Record button sat on top of the "Tap Record and start talking..." guidance.
2. **A natural speaking pause cleared the whole transcript (CRITICAL).** Pausing for a moment
   (not the Pause button) made the accumulated note text disappear.
3. **Keyword-led phrases were transcribed literally.** "Mira read that back to me" was written
   into the note instead of running the command, because command matching rejected trailing filler
   like "to me".
4. **No way to delete notes.** The Stream list had no swipe-to-delete.
5. **The waveform was static.** The bars under the live text never moved while speaking - they read
   as a static dashed line.
6. **The note card showed "1 paragraphs".** A paragraph count with broken pluralization that told
   the user little.
7. **No way to play back a recording.** The user could not play a note's recording.

## Root cause

1. The Record button was a `ZStack(alignment: .bottom)` layer over the content. The scrolling list
   reserved bottom room for it, but the centered empty-state VStack did not, so the button drew over
   the help text.
2. `SFSpeechRecognitionTask` ends not only on a clean `isFinal` result but also on an ERROR - a
   no-speech / natural-pause timeout or a duration limit. The service auto-restarts a fresh task to
   stay continuous. The old code committed text as a paragraph ONLY when `isFinal` was true; when a
   task ended by ERROR it emitted the last words as a `.partial` (uncommitted). The replacement
   task's first (empty) partials then OVERWROTE `partial` in the view model, so the words spoken just
   before the pause were lost. Committed paragraphs were safe; the IN-PROGRESS partial at the seam
   was not.
3. The parser required the remainder after the control word to BE a command phrase exactly, with only
   "please" as tolerated filler. "read that back to me" left "to me" dangling, so it failed to match
   and fell through to text. The strict-match design (spec 0003) was chosen to avoid false-fires, but
   it also meant a keyword-led near-miss got transcribed.
4. The list was a `ScrollView` + `LazyVStack`; SwiftUI swipe actions need a `List`.
5. Two contributors. The RMS->level mapping (`rms * 12`) was too weak for normal speech (float-PCM
   RMS ~0.02...0.08), so `level` hovered near the waveform floor and the view model's smoothing
   pulled it lower. (The mapping was the fixable part; whether the mic emits level at all can only be
   confirmed on device.)
6. `NoteCard` rendered `note.paragraphCount` with a hard-coded " paragraphs" suffix.
7. Playback was already wired (detail view Play control + navigation), but issue 2 could prevent a
   recording from ever being saved/associated, and the recording was not discoverable from the list.

## Fix

1. Moved the Record button into `.safeAreaInset(edge: .bottom)` and center the empty state in the
   frame that REMAINS after the inset, so the button reserves its own height under both the empty
   state and the list. Verified in the simulator (design/screenshots/0005-empty-state-no-overlap.png).
2. COMMIT-ON-END invariant: when a recognition task ENDS (final OR error) with any transcription
   text, the service emits it as `.finalizedSegment` (a committed paragraph), not a partial. A
   still-running task's mid-phrase update stays a partial. So the words captured right before a pause
   become a paragraph and survive the fresh task's replacing partials.
3. New parse model (supersedes the strict-match decision): if a segment LEADS with the control word
   it is COMMAND MODE and is never transcribed. The remainder is parsed tolerantly - leading/trailing
   filler ("please", "to me", "for me", "the", "that", "it") is stripped, and inner optional filler
   is ignored - then matched against the known commands. A match runs; a keyword-led NON-match is
   DROPPED (not transcribed) and shows a brief "Sorry, I didn't catch that command" chip. A
   mid-sentence keyword mention is still ordinary text. Keyword-led-unrecognized now DROPS rather than
   mis-firing, so there is still no wrong-command data loss.
4. Converted the notes list to a `List` with `.swipeActions` (iOS-standard, full-swipe) that calls
   `StreamFeed.delete(id:)` -> `NoteStoreDriver.delete(id:)` -> `NoteStoring.delete(id:)` (which
   removes the sibling audio), then reloads. River Mist styling kept via clear row/list backgrounds
   and hidden separators.
5. Split the RMS->level mapping into a testable `normalizedLevel(fromRMS:)` with a perceptual `sqrt`
   curve and higher gain, so normal speaking (~0.03...0.06 RMS) lands well above the 0.12 waveform
   floor and saturates at 1 for loud input. The waveform already animates on `level`.
6. Added `Note.wordCount` and `Note.wordCountLabel` ("1 word" / "12 words"), used in `NoteCard` and
   the detail header.
7. Fixing 2 restores recording persistence (audio filename + timings are saved on a normal
   record-then-stop). Added a small play affordance on cards for notes with audio; tapping the card
   still navigates to the detail Play control.

### Needs device retest (live mic)

- **#2** - confirm a real natural pause mid-note keeps all prior text and continues the same note.
- **#3** - confirm "Mira read that back to me" runs read-back and a keyword-led gibberish shows the
  chip and drops.
- **#5** - confirm the bars visibly ride the voice while speaking (the mapping is tuned and tested;
  whether the mic level actually propagates is device-only).
- **#7** - confirm a note recorded on device surfaces the Play control and plays the real voice.

## Learning

- **A recognition-task restart must never lose the in-progress phrase.** When a background service
  auto-restarts a subtask to stay continuous, whatever the ending subtask holds must be COMMITTED at
  the seam, not left as transient state the next subtask can overwrite. "Ends" includes error/timeout
  ends, not just clean completions. Generalizes to any restart-to-continue loop over a stream.
- **A strict "no false-fire" rule can become a "silent literal" bug.** Rejecting a near-miss keyword
  phrase back into the transcript is itself a failure mode the user notices. When the user's intent is
  "anything starting with my keyword is a command", make keyword-led the trigger and DROP unrecognized
  commands with visible feedback, rather than transcribing them - no wrong action, no silent literal.
- **Pin a floating control with `safeAreaInset`, not a `ZStack` overlay.** An inset reserves layout
  space so content (including a centered empty state) can never sit under the control; an overlay only
  looks right for the one layout you happened to pad.
- **Tune-and-test the perceptual mapping even when the end-to-end path is device-only.** The
  RMS->bar-height curve is pure and unit-testable; extracting it lets a regression that flattens the
  bars fail in CI even though the live mic can only be judged on hardware.
