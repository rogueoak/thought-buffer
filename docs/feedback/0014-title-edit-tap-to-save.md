# Feedback 0014 - Note title edit: tap out to save

## Source

Device feedback from Matthew (2026-07-19):

> When you edit the title of a note, you can't click out to save, you have to click
> Done. It feels unintuitive. Pressing elsewhere should just change the title and
> change your focus.

## Observation

On the note detail page the title is an inline editable header (spec 0009). Once you
tap it to edit, the ONLY way to commit was the Done button in the toolbar: tapping
elsewhere (the background, or into the body) left the title field focused, or lost the
edit. That is unlike every other iOS text field, where tapping away resigns focus.

## Fix

In `NoteDetailView`, commit the title whenever the title field loses focus, so tapping
away behaves exactly like Done:

- The title `TextField` is already driven by `@FocusState private var titleFocused` and
  committed by `commitTitle()`, which reads the LIVE `titleDraft` (not a stale
  `paragraphs`-derived value - the spec 0009 mutual-exclusivity fix guards that). An
  `.onChange(of: titleFocused)` observer calls `commitTitle()` when focus is lost while
  `isEditingTitle` is still set, so any way of resigning focus saves the title.
- A background tap (a `simultaneousGesture` on the screen background, enabled only while
  `isEditingTitle`) resigns the title focus, which the observer then commits. It is
  `simultaneous` and gated so it never steals a tap from the note text, its buttons, or
  the title field itself.
- Mutual exclusivity is preserved: tapping into the body resigns the title field's
  focus, so the observer commits the title FIRST, before body editing begins - the typed
  title is never dropped. The `isEditingTitle` guard also stops `commitTitle`'s own
  `titleFocused = false` from re-entering, and stops a body-focus change from firing a
  title commit.
- The Done button still calls `commitTitle()` and behaves exactly as before.

## Acceptance

- Editing the title and tapping the background saves the title and resigns focus, with no
  Done tap needed.
- Tapping from the title into the body commits the title (keeping the typed text), then
  begins body editing.
- Done still commits the title.
- No in-flight title text is ever dropped.
- Suite stays green (focus-loss behavior itself is manually verified on device; the pure
  commit rule `Note.resolveTitleEdit` is already unit-tested).
