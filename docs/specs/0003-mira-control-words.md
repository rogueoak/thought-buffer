# 0003 - Mira control words

## Problem

Dictation (spec 0002) turns speech into a saved note, but editing still means touching the
screen. The whole point of Thought Stream is hands-free capture: you should be able to fix a
stray sentence, start a fresh note, or hear what you just said without stopping to tap. This
milestone adds voice editing. Mid-dictation you say a control word ("Mira") and a command, and
the app acts on it instead of writing it into your note.

Who it is for: on-device testers who now capture real notes and want to prove the hands-free
editing loop before the Settings, CarPlay, and sync milestones build on it.

## Outcome

While recording, speaking a control-word command runs an action rather than committing text:

- "Mira remove the last sentence" -> the last sentence of the note is deleted.
- "Mira remove the last paragraph" -> the last paragraph is deleted.
- "Mira new note" -> the current note is saved and a fresh one begins; the session keeps running.
- "Mira read that back" -> the last paragraph is spoken aloud (text to speech).

The command phrase itself never lands in the note. When a command fires, a brief control chip
appears in the dictation screen ("Mira - removed last sentence" / "new note" / "read that back")
in the muted token style, then auto-dismisses. While Mira reads a paragraph aloud, capture
pauses so the spoken audio does not feed back into recognition, then resumes.

## Scope

In:
- The four commands above, with the control word fixed to "Mira" (a single injected constant).
- A pure `MiraCommandParser` that maps a finalized segment to a command or nil, case-insensitive,
  tolerant of common phrasings and the "delete"/"remove" synonym.
- Extending the `TextProcessor` seam so a processor can consume a segment as a command, drop it,
  or pass/transform text - keeping passthrough behavior and room for a future text->text
  processor to compose.
- A `MiraTextProcessor` wired into the composition root, running on finalized segments before
  commit.
- Command execution in `DictationViewModel`: sentence/paragraph removal, new note (save + reset),
  read-back.
- A `Speaker` protocol (stubbable) with an `AVSpeechSynthesizer`-backed production impl, and the
  capture-pause-during-playback handling.
- A sentence tokenizer for "remove the last sentence".
- The transient command chip in `DictationView`.
- Unit tests: parser, note mutations, new note, read-back, and TextProcessor result routing.

Out (later milestones, seams left, nothing built):
- Configurable control phrase / custom assistant name (Settings milestone). The control word is
  an injected constant now so Settings can make it configurable later.
- Spelling overrides (a future text->text processor composed into the same seam).
- CarPlay, Siri, iCloud sync.

## Approach

### Command grammar

`MiraCommandParser.parse(_:)` takes a finalized segment and returns a `MiraCommand?`. It:

1. Lowercases and trims the segment, collapsing internal whitespace.
2. Requires the control word at the *start*: the segment must begin with "mira". This avoids
   misfiring on ordinary speech that merely mentions "Mira" mid-sentence. A trailing comma or
   filler after the control word ("mira, remove...") is tolerated.
3. Strips the control word, then matches the remainder against per-command patterns. Matching is
   phrase-based (normalized token sequence contains the key tokens in order), not exact-string,
   so filler words are tolerated.

Grammar (remainder after "mira", all case-insensitive; `[the]`/`[that]` optional filler):

- removeLastSentence: (remove | delete) [the] last sentence
- removeLastParagraph: (remove | delete) [the] last paragraph
- newNote: new note | start [a] new note
- readThatBack: read [that | it] back | read back [that | it]

If the remainder is empty (just "mira") or matches nothing, `parse` returns nil and the text is
committed normally. A segment that starts with "mira" but is not a recognized command is still
committed as text (the user may simply have said a name); we do not silently drop it.

### TextProcessor seam

The processor no longer returns a bare `String`. It returns a `ProcessedSegment`:

- `.text(String)` - transformed (or unchanged) text to commit as a paragraph.
- `.command(MiraCommand)` - the segment was a command; suppress it from the note and act.
- `.drop` - discard the segment entirely (reserved; not emitted by the shipped processors).

`PassthroughTextProcessor.process` returns `.text(text)`. `MiraTextProcessor` wraps a parser
plus the control word: it returns `.command` when the parser recognizes the segment, else
`.text(text)`. This keeps passthrough behavior and leaves room for a future spelling-override
processor to be composed (parse for a command first, otherwise run the text transform and return
`.text`).

The partial phrase is still processed as plain text for display (`process` on a partial can only
yield `.text`; a half-spoken command should not fire until it finalizes), so the view model reads
`.text` from the partial result and ignores any non-text case there.

### Command execution (DictationViewModel)

The view model owns the note, so it executes commands:

- removeLastSentence: drop the last sentence of the last paragraph using the sentence tokenizer.
  If the paragraph becomes empty, drop it too, so the note stays coherent.
- removeLastParagraph: drop the last committed paragraph.
- newNote: fold any live partial, save the current note through `NoteStoring` (if non-empty),
  then reset paragraphs/partial and mint a fresh note id + created date. The capture session is
  untouched, so recording continues into the new note.
- readThatBack: hand the last paragraph (or the whole note if there is one paragraph) to the
  `Speaker`.

Each fired command sets a transient `lastCommand` banner value the view renders as a chip and
clears after a short delay.

### Text to speech and feedback avoidance

`Speaker` is a small protocol (`speak(_:)`, `stop()`) so tests inject a stub. The production
`SystemSpeaker` wraps `AVSpeechSynthesizer`.

Feedback avoidance: the microphone is live during dictation, so speaking a paragraph aloud would
be heard by the recognizer and written back into the note. Before speaking, the view model
pauses capture (same path as the Pause control, which tears down the engine, the task, and
deactivates the record audio session). It sets the audio session to `.playback` for the duration
of the utterance, speaks, and on the synthesizer's `didFinish`/`didCancel` delegate callback
restores capture (reactivates the record session and restarts a task) if the session was
recording when read-back began. This clean record -> playback -> record transition keeps the
spoken audio out of recognition. The `Speaker` protocol reports completion back to the view
model via a callback so the resume is driven by "speech finished", not a guess at duration.

### Sentence tokenization

`SentenceTokenizer.sentences(in:)` splits a paragraph into sentences. It uses `NLTokenizer` with
unit `.sentence` (Natural Language framework), which handles terminal punctuation and common
abbreviations better than a naive split. "Remove the last sentence" drops the final element and
rejoins the rest; an empty result removes the paragraph.

## Acceptance

- [ ] `cd ios && xcodegen generate` and build for the `iPhone 17` simulator succeeds.
- [ ] Parser recognizes each of the four commands and reasonable phrasings, is case-insensitive,
      treats "delete" as "remove", requires the leading control word, and returns nil for
      ordinary speech (including a passing mention of "Mira").
- [ ] "Mira remove the last sentence" deletes the last sentence; the note stays coherent when a
      paragraph empties. Edge cases (single sentence, single paragraph, empty note) do not crash.
- [ ] "Mira remove the last paragraph" deletes the last paragraph.
- [ ] "Mira new note" saves the current note through the store and resets to an empty note while
      the session keeps running.
- [ ] "Mira read that back" invokes the `Speaker` with the last paragraph, and capture pauses
      during playback then resumes.
- [ ] The TextProcessor result routes correctly: a command segment is consumed (never committed),
      a text segment is committed.
- [ ] A command fires a transient chip in `DictationView` in the muted token style.
- [ ] Unit tests for all of the above pass, alongside the existing suite.
