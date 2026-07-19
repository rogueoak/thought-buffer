# Spec 0016 - Transcript refinement

## Motivation

Device feedback from Matthew (2026-07-19):

> What options do we have to refine the text after the recording is done? As in,
> remove the "umms", "yeah", "uh", fillers. Collect single sentences that got
> split across lines. Delete sentences retroactively when the user literally says
> something like "delete the last line".

Spoken notes carry disfluencies (filler words, false starts) and the recognizer
splits sentences across paragraphs on short pauses. This spec makes the saved text
read like written notes without changing what the user said in substance, and adds
a hands-free way to drop the last thing said.

The paragraph-flow half of "sentences split across lines" is fixed at capture time
in feedback 0012 (pause-based grouping). This spec covers filler removal, the
voice command, and a cleanup pass for text that was typed or imported.

## Decisions (from Matthew)

- **Cleanup is automatic, on by default**, with a Settings toggle to turn it off.
- Paragraph breaking is "flowing, like Notes" (implemented in feedback 0012).
- Cleanup is **non-destructive to audio**: the recording is never altered; only
  the transcript text is refined. Playback of a recorded note still plays the
  original audio.

## Scope

### 1. Filler-word removal (auto, toggleable)

A new `FillerRemovalProcessor` conforming to `TextProcessor`, composed into
`CompositeTextProcessor` AFTER the Mira command split and spelling overrides, so it
only ever touches committed dictation text (never the command portion).

- Removes standalone hesitation tokens from a **conservative** default list:
  `um, umm, uh, uhh, erm, hmm, mm, mmm, er, ah, uh-huh` (as whole tokens only).
- Never removes a token that is part of a real word ("I am", "a hummingbird"): it
  matches whole tokens, case-insensitively, and preserves surrounding words,
  casing, and punctuation.
- Collapses the whitespace and dangling punctuation a removed filler leaves behind
  (e.g. "So, um, yeah -> "So, yeah") and re-capitalizes a sentence whose leading
  filler was removed.
- If removing fillers would empty a segment, the segment is dropped (no empty
  paragraph).
- Risky words that are often meaningful ("like", "so", "you know", "yeah",
  "right") are NOT in the default set. Rationale documented inline: false
  positives silently change meaning, which is worse than leaving a filler in. A
  later milestone can add an opt-in "aggressive" list if wanted.

### 2. "Delete the last line" and "scratch that" voice commands

Extend the Mira grammar (`MiraCommandParser`) so, after the control word:

- "delete the last line" / "delete last line" / "remove last line" -> the existing
  `removeLastSentence` action. Rationale: a spoken "line" maps to the last thing
  said (one sentence), which is what "scratch that last bit" intends. "delete the
  last paragraph" remains the way to drop a whole block.
- "scratch that" -> `removeLastSentence` (natural phrasing, no control word noun).

Add these phrasings to the cheat sheet detail without inventing new `MiraCommand`
cases (they reuse `removeLastSentence`).

### 3. Sentence-merge cleanup pass (edited / imported text)

New recordings are already flow-grouped (feedback 0012). For text that was typed,
edited, or loaded from an older note, provide a pure `TranscriptCleanup.reflow`
that merges obvious continuation lines: a paragraph that does NOT end in terminal
punctuation followed by a paragraph that begins lowercase is joined with a space.
Conservative - it never merges across a blank line the user inserted deliberately,
and never splits.

The auto-clean setting, when on, applies filler removal live (via the processor
chain) and offers reflow as part of the same toggle for edited notes. Reflow is
NOT run destructively on load; it is applied when the auto-clean setting is on and
a note is saved after an edit, so an untouched old note is never silently rewritten
until the user edits it.

### 4. Settings

Add `refineTranscript: Bool` (default `true`) to `SettingsStoring` and a toggle in
`SettingsView` ("Refine transcript", subtitle explaining it removes filler words
and tidies sentences, and that audio is never changed). Wired into
`AppDependencies.makeTextProcessor` so the filler stage is present only when on,
taking effect on the next dictation session (same lifecycle as the control word).

## Non-goals

- No cloud / LLM rewriting. All refinement is local, deterministic, and rule-based
  (privacy framing is core to the app).
- No grammar rewriting or summarization - only filler removal, whitespace
  tidying, and continuation merging.
- No alteration of recorded audio.
- No aggressive filler list in this milestone (kept conservative by decision).

## Acceptance

- With refine ON (default), a dictated segment "um so, uh, the plan" saves as "So,
  the plan" (fillers gone, spacing/caps tidy); audio unchanged.
- With refine OFF, text is committed verbatim (fillers kept).
- "I am hungry" is never altered by filler removal ("am"/"ah" not mis-stripped).
- After the control word, "delete the last line" and "scratch that" both remove the
  last sentence; the cheat sheet lists them.
- `TranscriptCleanup.reflow` merges a lowercase continuation line into its
  predecessor and leaves deliberately separate paragraphs alone; it is pure and
  unit-tested.
- Settings toggle persists and gates the processor; new sessions honor the change.
- Full suite stays green; new pure units (`FillerRemovalProcessor`,
  `TranscriptCleanup`, grammar additions) are unit-tested including negative cases.
