# Spec 0020 - Undoable delete (menu delete + shake-to-undo)

## Motivation

Device feedback from Matthew (2026-07-19):

> After a delete, shaking the device should offer an undo delete action. Also,
> there should be a delete option in the triple dot menu.

Deletes should be recoverable. iOS users expect the system "Shake to Undo"
gesture, and a delete action belongs in the note's actions menu.

## Depends on

Spec 0017 (note actions "..." menu) must land first - this adds a Delete item to
that menu. Sequence after the 0017 PR merges.

## Scope

### 1. Recoverable delete (trash + restore)

Deleting a note must not immediately destroy its files. Extend the stores
(`NoteStore` and `ICloudNoteStore`) with a soft-delete:

- On delete, MOVE the note's `<id>.md` (and sibling `<id>.m4a` when present) into a
  per-store trash directory rather than removing them. Return a lightweight
  `DeletedNote` token (former location + id) sufficient to restore.
- `restore(_:)` moves the files back to their original folder path (recreating the
  folder if the user deleted it meanwhile is out of scope; restore to root if the
  original folder is gone, and note that).
- `purge(_:)` permanently removes a trashed note. Trash is purged when the undo
  window closes (committed), and opportunistically on launch for tokens with no
  pending undo.
- Path safety: reuse the existing `resolvedFolderDirectory` guards; the trash dir
  is inside the store root and never escapes it.

### 2. UndoManager integration + shake-to-undo

Route delete through the SwiftUI `@Environment(\.undoManager)` so the system
"Shake to Undo" gesture offers "Undo Delete" (and redo). Register the delete with
an undo that calls `restore` and a redo that re-deletes. Keep
`applicationSupportsShakeToEdit` at its default (true). If the environment
UndoManager is unavailable in the relevant scene, provide a minimal UIKit bridge
(a first-responder view exposing an UndoManager) - but prefer the SwiftUI path.

### 3. In-app undo affordance

In addition to shake, show a brief, non-blocking "Note deleted - Undo" affordance
(reuse the existing chip/banner/snackbar pattern; ~5 s) so undo is discoverable
without shaking. Tapping Undo calls the same restore path.

### 4. Delete in the actions menu

Add a destructive "Delete" action to the note detail "..." menu (spec 0017) and, if
consistent, to the list-row long-press context menu. Deleting from the menu uses
the same undoable path. After delete from the detail screen, dismiss back to the
list (with the undo affordance visible there).

## Product defaults (reasonable; adjust if desired)

- Trash-and-restore (not hard delete) so undo is reliable even after navigation.
- Undo affordance ~5 s; shake-to-undo works as long as the UndoManager retains the
  action (typically the current screen's lifetime).
- Committing (purge) happens when the undo window elapses or the app is backgrounded
  with no pending in-flight restore.

## Non-goals

- No multi-level trash browser / "recently deleted" screen (single-step undo only).
- No undo for edits in this spec (delete only).

## Acceptance

- Deleting a note (menu, list swipe, or detail) moves it to trash and shows an
  "Undo" affordance; shaking the device offers "Undo Delete".
- Undo (shake or tap) fully restores the note, its audio, and its folder location.
- After the undo window, the note is purged; trash does not accumulate across
  launches.
- Delete path is safe: files only ever move within the store root; a restore whose
  original folder is gone lands the note at root without error.
- Store soft-delete/restore/purge are unit-tested (including the missing-folder
  restore and audio sibling); suite stays green.
