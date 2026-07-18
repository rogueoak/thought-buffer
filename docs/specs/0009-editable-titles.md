# 0009 - Editable note titles

## Problem

Every note shows a title (on the card and the detail nav bar), but it is always auto-derived and the
user cannot change it. Two gaps:

1. The derived title is the first **line** of the note, so a long first paragraph becomes a
   run-on title. The natural title is the first **sentence** - what you said before your first pause.
2. There is no way to give a note a real, human title separate from its body. A note about "the
   Q3 planning offsite" is stuck with whatever its first words happened to be.

For a notes app you revisit, a good, editable title is how you find the thought again.

## Outcome

- A new note's default title is its **first sentence** (up to the first natural pause), capped and
  tidy - not the whole first line.
- On a saved note's page, the user can **edit the title** independent of the body: tap the title,
  type, commit. The edited title sticks - later body edits do not overwrite it.
- Clearing the title back to empty **resets** it to the auto-derived first sentence (a clean way to
  "undo" a custom title), mirroring the control-phrase reset in Settings.
- Everything else (card, detail header, CarPlay browser, Files-app frontmatter) shows the effective
  title unchanged; old notes load exactly as before.

## Scope

**In:**
- `Note.deriveTitle` switches from first-line to first-sentence (via the existing `SentenceTokenizer`).
- `Note` gains a persisted `hasCustomTitle` flag (frontmatter `titleCustom: true`, written only when
  true) so a user title is distinguished from a derived one and survives body edits.
- Title-edit affordance on `NoteDetailView` (tap-to-edit, matching the body's tap-to-edit from
  feedback 0010), gated on a persisting call site.
- `DictationViewModel` preserves a resumed note's custom title instead of re-deriving it.

**Out:**
- Editing the title on the record screen mid-session (titles are edited after, on the note page).
- Cloud/rename propagation beyond the existing per-note save.
- Renaming via voice command.

## Approach

- **First-sentence derivation.** `deriveTitle` takes the first non-empty paragraph and returns its
  first sentence (`SentenceTokenizer.sentences(in:).first`), keeping the existing cap (60, ellipsized)
  and trailing-period trim, and the dated fallback when empty. A single-sentence first paragraph is
  unchanged, so existing derivations (and their tests) still hold; a multi-sentence first paragraph
  now yields just the opening sentence.
- **Custom-title flag, conservative parse.** Parsing still prefers a stored `title:` when present
  (so every existing file keeps its title byte-for-byte); the new `titleCustom` field only sets
  `hasCustomTitle`. The flag governs **edit-time** behavior: when a note is NOT custom, a body edit
  re-derives the title; when it IS custom, a body edit leaves the title alone. Serialization writes
  `titleCustom: true` only for a custom note, so a non-custom note serializes exactly as before
  (tolerant-parse contract preserved).
- **Detail edit UI.** The note page shows the title as a prominent, tappable header above the meta
  row. Tapping it (only where `onCommitEdit` is supplied) swaps in a `TextField`; a Done control
  commits. A non-empty commit sets the title and marks the note custom; an empty commit clears custom
  and restores the derived first sentence. `currentNote` builds the saved note with the effective
  title and the `hasCustomTitle` flag, so the existing `onCommitEdit` persistence path carries it
  through with no new seam.
- **Resume.** `DictationViewModel` seeds `hasCustomTitle`/`customTitle` from a resumed note and keeps
  the custom title on save, so resuming a titled note never silently reverts it to a derived one.

## Acceptance

- [ ] A note whose first paragraph is "Hello there. More words." derives the title "Hello there".
- [ ] A single-sentence first paragraph derives as before (existing title tests pass).
- [ ] A custom title round-trips through Markdown (`titleCustom: true` written and parsed back to
      `hasCustomTitle == true`); a non-custom note writes no `titleCustom` key and parses to `false`.
- [ ] Editing the title on the note page and then editing the body keeps the custom title.
- [ ] Editing the body of a non-custom note updates its title to the new first sentence.
- [ ] Clearing the title to empty restores the derived first sentence and marks the note non-custom.
- [ ] Resuming a custom-titled note and saving preserves the custom title.
- [ ] Full suite green.
