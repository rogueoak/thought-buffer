# 0011 - Home and note UX polish, round 2

Three refinements from using the app on device. No capture or storage change.

## Symptom

1. **Recordings filter is clutter.** The Thoughts toolbar's leading "Recordings" control (feedback
   0008/0010) filters the list to notes with a kept recording. In practice it adds a mode toggle to
   the home screen that few reach for and that competes with the record affordances for attention.
   The developer wants it gone from the main screen.
2. **No one-tap new thought from a note.** On a note's detail page there is no way to start a fresh
   thought without navigating back to the list first. The whole product is "capture a thought the
   moment you have it", so a note page missing the mic (and the gear) costs a tap at exactly the
   wrong time.
3. **The list's "x mins ago" is stale.** On a note card the timestamp reads roughly the note's own
   recording length ("3 min ago" for a 3-minute note) and never updates; opening the note shows the
   correct age. The relative-time label also sits a touch far from its clock icon.

## Root cause

1. Product/UX decision, not a defect: the filter earned its keep when CarPlay was the only place to
   browse recordings, but on the phone it is a rarely-used mode switch. Recordings remain reachable
   (every recorded note still shows its play affordance and duration inline).
2. `NoteDetailView` renders only a Done button (while editing) in its toolbar; it never had the
   mic/gear that `StreamListView` carries, and it has no seam to request a new session or open
   Settings.
3. `NoteCard` computes `RelativeTime.label(for:relativeTo:)` **once**, at the moment its body is
   built, with the default `relativeTo: Date()`. SwiftUI has no wall-clock dependency to invalidate
   on, so the string **freezes** at whatever it was when the list last rendered - and the list most
   recently rendered right after the note saved, when time-since-creation (`createdAt` is captured at
   session start) is approximately the recording's own duration. Hence "the x mins ago is the length
   of the post". `NoteDetailView` looks correct only because it is constructed fresh on each
   navigation, so it recomputes against a current `now`. The two views share identical code; the
   difference is purely staleness, not a different `createdAt`.

## Fix

1. Remove the recordings-only filter from `StreamListView`: drop the toolbar toggle, the
   `showRecordingsOnly` state, the `displayedNotes` filter, and the filter-specific empty-state copy.
   The list always shows every note.
2. Add a toolbar to `NoteDetailView` with a mic (starts a new session) and a gear (opens Settings),
   mirroring the Stream toolbar, wired through two optional callbacks (`onNewThought`,
   `onOpenSettings`) supplied by `StreamListView`'s navigation destination so the detail view stays
   presentational and testable. The existing Done button (while editing) is unchanged.
3. Refresh the card's relative-time label over time and against a live reference: wrap it in a
   `TimelineView(.periodic(by: 60))` and pass `context.date` as the `relativeTo` reference, so the
   label recomputes every minute and is never frozen. Tighten the clock glyph against its text with a
   small custom icon+text pairing (spacing `x1`) instead of the default `Label` gap. Apply the same
   `TimelineView` fix to `NoteDetailView`'s timestamp (engineer review): it shared the identical defect
   and only looked correct because the detail page is rebuilt on each navigation - it would freeze if
   the page stayed open.

## Learning

A SwiftUI label derived from the current time is **frozen at render**, not live: with no time-based
dependency, the view never re-invalidates, so a "3 minutes ago" written just after save still reads
"3 minutes ago" an hour later - and it silently looked correct wherever the view happened to be
reconstructed (the freshly-pushed detail page), masking the bug on the long-lived list. Any label
that is a function of "now" (relative timestamps, countdowns, "expires in") must carry an explicit
time dependency - a `TimelineView` or a ticking reference date - or it will drift on any screen that
stays on-screen. Generalizes to every relative-time or elapsed display in a persistent list.
