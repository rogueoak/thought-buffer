# Spec 0021 - Full-text search and bottom-bar redesign

## Motivation

Device feedback from Matthew (2026-07-19):

> There should be a search bar at the bottom for finding a note. It should search
> all text, not just the title. This will change the bottom bar. I want search
> filling most of the space, new note and record buttons should be on the right.
> When you enter a note, there should still be a search bar with the resume button
> on the right. We will have to drop the text for the record and resume buttons. In
> the empty state of a list or folder, the record button should be in the middle of
> the screen with text and a new note button right below it.

## Scope

### 1. Persistent bottom bar (new shared component)

A single reusable bottom-bar component used across the list, folder, and note-detail
screens, laid out as: a SEARCH FIELD filling most of the width on the left, and a
small set of ICON-ONLY action buttons on the right (labels dropped to make room).

- **List / folder screens:** search field + [new-note icon] + [record icon].
- **Note-detail screen:** search field + [resume icon] (resume/append recording to
  this note; only when resuming is applicable per audio-retention settings).
- The now-playing bar (spec 0015) continues to appear above the bottom bar when
  playback is active; the two must stack cleanly in the bottom safe-area inset.
- RECONCILE the undo-delete affordance (spec 0020), which is currently pinned to
  `.bottom` with a fixed clearance for the old bare toolbar: this redesign owns
  making that overlay sit above the new persistent bottom bar + now-playing bar via
  the shared safe-area inset math, not a hardcoded offset.
- Canopy tokens throughout; the record/resume icon keeps its recording-state
  affordance (the pulsing/active state) without a text label.

### 2. Full-text search

- The search field filters to notes whose TITLE or ANY body paragraph contains the
  query (case-insensitive, diacritic-insensitive, substring). Not title-only.
- Search is GLOBAL: it finds notes anywhere in the folder tree, presented as a flat
  result list; tapping a result opens that note. Clearing the field restores the
  normal folder view.
- Implement the matching as a PURE, unit-testable function over the loaded notes
  (title + paragraphs), so ranking/among-folder behavior is testable without UI.
  Reuse the notes the store already loads; no separate index needed for the current
  scale (revisit if note counts grow large).
- Searching from the note-detail bottom bar performs the same global search (routes
  to results), so search is reachable from anywhere.

### 3. Empty state

When a list or folder has no notes, show a centered call to action instead of an
empty list: the RECORD button in the middle of the screen WITH its text label, and a
NEW-NOTE button directly below it. (This is the one place record/new-note keep their
labels.) The bottom bar's search field may hide or disable in a truly empty store
(nothing to search) - keep it visible in a non-empty store filtered to zero results,
showing a "no matches" state.

## Design notes

- Factor the bottom bar so screens pass in their right-side actions; do not fork it
  per screen. Coordinate with the shared note-actions menu (spec 0017/0020) styling.
- Preserve accessibility labels on the now-unlabeled icon buttons ("New note",
  "Record", "Resume recording", "Search notes").
- Keyboard: the search field should not fight the dictation mic; searching and
  recording are distinct actions.

## Non-goals

- No search history, saved searches, or fuzzy/semantic search (substring only).
- No per-note in-note find (search is note-finding, not within-note).
- No server/cloud search - fully local.

## Device-feedback additions (2026-07-19)

A round of device feedback arriving during the build folded four folder-screen items into this same PR
(they touch the files this spec rewrites); see `docs/feedback/0018-search-bottom-bar-device-feedback.md`.

- **Consistent title below the toolbar** (revises feedback 0016). Both the root "Thoughts" screen and
  the folder screens show a large title BELOW the toolbar buttons, not the inline title feedback 0016
  chose (which read as cramped). Feedback 0016's note is superseded.
- **Folder rename fixed.** The three folder alerts (New / Rename / Delete) were stacked on one view
  node, which broke rename presentation; they are un-stacked into one `FolderDialog` host, each on its
  own anchor. Locked with a driver-level rename test.
- **Shake to Undo fixed.** The delete registered on `@Environment(\.undoManager)` (nil in plain
  SwiftUI); a `UndoManagerHost` now vends a stable first-responder-backed `UndoManager` that is injected
  into the deletion controller, so the shake reaches the registered action.
- **Contextual record + new thought.** Recording or creating a thought inside a folder files it in that
  folder (the actions carry the current folder path into the dictation session); hands-free starts stay
  at the root.

## Acceptance

- The bottom bar shows a wide search field with icon-only actions on the right, on
  list, folder, and note screens (record on lists, resume on notes).
- Typing filters to notes matching title OR body text, across all folders; tapping
  opens the note; clearing restores the view.
- The pure search-match function is unit-tested: title match, body-paragraph match,
  case/diacritic insensitivity, no-match, multi-folder results.
- Empty folder/list shows the centered record (with label) + new-note-below CTA.
- Now-playing bar and bottom bar coexist without overlap.
- Suite stays green; new pure seams unit-tested.
