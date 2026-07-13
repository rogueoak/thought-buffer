# 0006 - Device speech accumulation (two device-only bugs the 0005 fix missed)

Two CRITICAL bugs survived the feedback 0005 fixes because the simulator and the tests did not
model how a real device actually feeds speech. Both trace to ONE misunderstanding of the
recognition task's lifecycle, so they are captured together.

## The shared root cause

On a real device a single `SFSpeechRecognitionTask` ACCUMULATES the entire spoken passage into one
growing `bestTranscription` and only "finalizes" when the task ends (a pause / no-speech timeout /
duration limit). The app then restarts a fresh task against the same live audio to stay continuous.
The 0005 fix reasoned about the task as if it emitted one short phrase per pause; it does not. Two
consequences fell out of that mismatch:

- **A task can end with an ERROR and a NIL result** (no final transcription at all). The words are
  then held ONLY as the in-progress partial the task had been accumulating - text the 0005 fix never
  committed, because it only committed when the ending result carried text. The fresh task's
  replacing partials then overwrote it and the passage was lost.
- **A spoken command lands in the MIDDLE or END of one accumulating segment**, not at its start. The
  0005 model fired a command only when the segment STARTED with the control word, so for real
  continuous speech ("here is my note Mira new note") the command never fired at all - the control
  word was buried mid-segment.

## Symptom

1. **A long pause reset the note (CRITICAL).** After the 0005 fix, a natural pause could STILL wipe
   the in-progress words: when the task ended with an error and a nil result, the last-heard words
   (held only as the partial) were never committed and the restart's fresh partials cleared them.
2. **Mira commands never fired on device (CRITICAL).** Speaking "Mira new note" (or any command) as
   part of continuous dictation did nothing - the control word was mid-segment, not at the start, so
   the "starts-with-keyword" parser treated the whole thing as text.

## Fix

### Fix A - never lose the in-progress partial across a task restart

`SpeechDictationService` now tracks the current task's latest partial (`lastPartialText`), updated on
every partial and reset when a new task starts. On ANY task end (`isFinal` OR error) it commits the
BEST available text as a `.finalizedSegment`: the result's transcription when non-empty, otherwise
the tracked partial. The decision is a pure, unit-tested `resolveEnd(resultText:lastPartial:)`. A
clean final already CONTAINS the partial, so it is used ONCE (never also the partial) - no double
commit - and empty/whitespace is never committed. The range is emitted only when the RESULT carried
the committed text (a nil-result end has no timings, so it commits with a nil range).

### Fix B - detect the control word ANYWHERE and split at it

The parser/processor moved from "starts-with-keyword" to "split-at-keyword". `MiraCommandParser.parse`
now finds the FIRST control-word token anywhere in the segment (using the CONFIGURED control word):

- No control word -> `.text` (commit the whole segment as a paragraph, as before).
- Control word found -> `.split(preText:command:)`. The text BEFORE the control word is committed as a
  normal dictation paragraph (if non-empty); the text FROM the control word to the end is COMMAND
  MODE - parsed with the existing tolerant matching/filler - and either executes (`.command`) or, if
  keyword-led but unrecognized, is dropped (not transcribed) and shows the existing "Sorry, I didn't
  catch that command" chip.

`ProcessedSegment` gained the same `.split(preText:command:)` shape; `CompositeTextProcessor` applies
spelling overrides to the `preText` ONLY, never to the command portion; `DictationViewModel`
`handleFinalized` commits the pre-text paragraph then runs/drops the command, integrating with the
existing partial-folding used by `newNote`/`readThatBack`. Commands still EXECUTE only on
FINALIZATION, never on a live partial. For the live partial display, once a control-word token is
present only the pre-keyword text is shown (the forming command is not displayed).

### Intentional tradeoff

Because the control word switches the REST of the utterance to command mode, dictation that literally
contains the assistant's name mid-sentence is treated as a command from that point on ("I told Mira
about the plan" commits "I told" and drops "about the plan" with the didn't-catch chip). The user
accepts this and can choose an uncommon control word to avoid it.

### Needs device retest (live mic)

- **A** - confirm a real long pause mid-note keeps ALL prior text and the just-spoken words, and
  continues the same note (the nil-result error end is device-only; the simulator does not reproduce
  it).
- **B** - confirm "here is my note Mira new note" spoken as one continuous utterance commits "here is
  my note" and starts a new note; "remember the milk Mira read that back to me" commits and reads
  back; "... Mira flibber" keeps the pre-text and shows the chip; a custom control word is honored.

## Learning

- **Model the real stream, not the simplified one.** The 0005 fix reasoned about the recognition task
  as one-phrase-per-pause; on device it accumulates the whole passage and finalizes only on end
  (sometimes an error end with a nil result). A fix built against a simulator/test model that does not
  reproduce the real feed can look correct and still ship the bug. When the real behavior is
  device-only, extract the decision into a pure function and TEST it against the real shape (nil
  result, mid-segment keyword, accumulating partial), not the shape the simulator happens to emit.
- **"At the start" is the wrong anchor for a marker in an accumulating stream.** A control token in a
  growing transcript arrives mid/end, not at position zero. Match the marker ANYWHERE and split
  around it; anchoring to the start silently disables the feature for the exact continuous input it
  was built for.
