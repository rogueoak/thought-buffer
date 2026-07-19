# Feedback 0015 - Note detail: duration icon matches the list card

## Source

Device feedback from Matthew (2026-07-19):

> On the note itself, the duration time has a dash and not the same icon as the listing
> card. That should match.

Clarified: "It should just use the same component."

## Observation

The recording duration appeared two different ways. On a list card (`NoteCard`) it read as
a timer glyph tight to the duration; on the note detail header (`NoteDetailView`) it read
as a dash separator ("... - 1:24") with no timer glyph. Same value, two renderings, so the
two screens looked inconsistent and could drift further apart over time.

## Fix

Unified into a shared `NoteMetaStats` component used by BOTH the list card and the note
detail header - one SwiftUI view that renders the clock/time-since-created pair AND the
timer/duration (or word-count) pair, each with the shared `CanopySpacing.x1` token
(feedback 0013) and the same `timer` / `text.alignleft` glyph. `NoteCard` and
`NoteDetailView` now both render `NoteMetaStats(note:)` instead of hand-rolling their own
metadata rows, so the duration icon and spacing are identical by construction and cannot
drift again. The detail view's dash separator is gone.

## Acceptance

- The note detail duration shows the SAME timer glyph and spacing as the list card.
- Both screens render the one shared `NoteMetaStats` component - there is no second,
  look-alike rendering.
- The detail view no longer uses a dash separator for the duration.
- Suite stays green (the visual match is manually verified on device; `metaStatLabel` and
  the duration formatter are already unit-tested).
