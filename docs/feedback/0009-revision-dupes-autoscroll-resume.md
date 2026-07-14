# Feedback 0009: revision duplicates, transcript auto-scroll, bottom Resume

A second round of on-device testing after feedback 0008.

## 1. Self-correction produces duplicate paragraphs (bug)

### What happened

A saved note showed pairs like "I'm saying the" + "I'msayingthe.com" and "What kind of games" +
"Kind of games" as separate paragraphs. Each pair is ONE utterance the recognizer revised, split
into two.

### Root cause

`SpeechDictationService.isReset` compared the previous and current partial by character-level common
PREFIX. A revision that collapses spacing ("I'm saying the" -> "I'msayingthe.com") or drops a leading
word ("What kind of games" -> "Kind of games") diverges at the very start, so the prefix ratio
collapsed and the revision read as a NEW utterance - committing the pre-revision text as its own
paragraph before adopting the corrected text.

### Fix

`isReset` now normalizes both strings (lowercase, whitespace and punctuation removed) and treats it
as a revision (NOT a reset) when one compact string CONTAINS the other, or when they overlap by >=60%
at the start OR the end of the shorter string. Genuinely unrelated utterances still share little at
either end and are still committed as separate paragraphs. Unit-tested with the exact screenshot
cases and with unrelated-utterance guards so the change does not start merging distinct paragraphs.

## 2. Transcript auto-scrolls while recording

The live-capture text area now follows the newest words: a `ScrollViewReader` scrolls to a bottom
anchor whenever the partial or the paragraph count changes, so the live caret stays in view instead
of the text running off the bottom of the card.

## 3. Resume button centered at the bottom of the note

On a saved note, Resume moved from an inline pill inside the card to a prominent, centered pill
pinned to the bottom of the screen (a bottom safe-area inset), clear of the scrolling note body and
hidden while editing text.

## Retest on device

- Speak so the recognizer self-corrects (spacing/URL fixes, dropped leading words): the correction
  updates in place, no duplicate paragraph.
- While dictating a long note, the text area scrolls to keep the latest words visible.
- Open a saved note: Resume is centered at the bottom of the screen.
