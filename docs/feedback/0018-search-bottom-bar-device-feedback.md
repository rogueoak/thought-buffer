# Feedback 0018 - Device feedback during the search + bottom-bar redesign (spec 0021)

A round of device feedback from Matthew (2026-07-19) arriving while spec 0021 (full-text search +
bottom-bar redesign) was being built. All four items touch the folder-screen / bottom-host files spec
0021 was already rewriting, so they were folded into that one PR rather than split into a conflicting
branch. Each is captured here so the learnings feed forward.

## 1. Screen title placement (revises feedback 0016)

- **Symptom.** The inline "Thoughts" title (feedback 0016) reads as smooshed under the toolbar buttons,
  and a folder's name renders the same cramped way. The user wanted the title in a clear row BELOW the
  toolbar buttons, and CONSISTENT between the root list and folder screens.
- **Root cause.** Feedback 0016 chose `.navigationBarTitleDisplayMode(.inline)` to sit "Thoughts" on the
  same bar row as the mic/gear. That was a local optimization for the root that made the title compete
  with the buttons; folder screens inherited an inconsistent look.
- **Fix.** Both the root ("Thoughts") and every folder screen now use a large title
  (`.navigationBarTitleDisplayMode(.large)`), so the title sits below the toolbar buttons in its own row,
  reading identically across screens and balanced with the new persistent bottom bar. The feedback 0016
  note is superseded (its inline choice no longer holds).
- **Learning.** A title-placement choice made for ONE screen (the root) should be checked against the
  OTHER screens that share the chrome before it ships - an inline title that "fits" the root can read as
  cramped everywhere else. Prefer one consistent display mode across a navigation stack unless a screen
  has a specific reason to differ.

## 2. Folder rename was not working

- **Symptom.** Renaming a folder appeared to do nothing.
- **Root cause.** The STORE logic was correct (`NoteStore.renameFolder` / `ICloudNoteStore.renameFolder`
  sanitize, guard against clobbering a sibling, then `moveItem`; create worked). The fault was in the
  VIEW layer: the folder screen had THREE stacked `.alert(...)` modifiers on one view node (New folder /
  Rename / Delete), and the rename alert was presented straight from a `.contextMenu` action via a bool
  binding. Stacked alerts on one node and context-menu-triggered bool alerts are both classic SwiftUI
  flakiness sources - a sibling alert can swallow another's presentation, so the rename alert may not
  present (or its TextField edit may not commit), and nothing reaches the working store call.
- **Fix.** The three folder dialogs are now driven by ONE `FolderDialog` enum (`@State activeDialog`),
  and each alert hangs off its OWN hidden background anchor (`Color.clear.alert(...)`) via a per-case
  binding - so no two alerts share a node and none can lose the presentation race. The rename/new-folder
  text lives in a separate `@State folderNameField` so editing it does not churn the enum identity. A
  driver-level regression test (`FolderRenameDriverTests`) proves `StreamFeed.renameFolder(at:to:)` - the
  exact seam the UI calls - renames on disk, moves the folder's notes, returns the applied name, and
  republishes (plus conflict and invalid-name rejection).
- **Learning.** Do NOT stack multiple `.alert`/`.confirmationDialog` modifiers on one SwiftUI view node,
  and be wary of presenting a bool-driven alert directly from a `.contextMenu` action. Drive a screen's
  set of dialogs from ONE state (an enum) and host each on its own anchor (or use item-driven
  presentation), so presentation is deterministic. When a "store logic is correct but the feature does
  nothing" bug appears, suspect the presentation/interaction layer, and lock the working seam with a
  test at the driver level so a view-layer regression cannot silently disable it again.

## 3. Shake to Undo was not working

- **Symptom.** Shaking the device to undo a delete did nothing.
- **Root cause.** `NoteDeletionController` took its `UndoManager` from SwiftUI's
  `@Environment(\.undoManager)`, which in a plain SwiftUI tree is frequently NIL (no UIKit responder
  vends one). So the delete was registered with a nil manager, and the system shake gesture - which
  invokes the FIRST RESPONDER's `UndoManager` - found no registered action.
- **Fix.** A small, separable `UndoManagerHost` (`UIViewControllerRepresentable`) embeds a zero-size
  `UIViewController` that `canBecomeFirstResponder`, becomes first responder on appear, and vends a
  STABLE `UndoManager` from its `undoManager` override. The composition root injects THAT manager into
  the deletion controller, so `registerUndo`/`undo`/`redo` all operate on the manager the shake gesture
  actually resolves. `applicationSupportsShakeToEdit` stays at its default (true). A seam test proves a
  delete registers an "Undo Delete" action on the injected manager (the exact thing the nil environment
  manager prevented); the end-to-end shake gesture stays a manual-verify (system UI).
- **Learning.** `@Environment(\.undoManager)` is not a reliable source of an `UndoManager` in a plain
  SwiftUI app - if a feature depends on the system Undo/Shake gesture, vend a stable manager from a
  first-responder-backed controller and inject it, rather than trusting the environment to provide one.

## 4. Record / new-thought must be contextual to the current folder

- **Symptom.** Using the mic (record) button while inside a folder created the new thought at the ROOT,
  not in the folder being viewed. The user expected it to land in the current folder, like the new-text
  action should.
- **Root cause.** The record action routed through the shared session seam
  (`PendingSessionRoute.startNewSession()`) with no folder context, and the dictation view model created
  its note at the top level (`folderPath = []`). The dictation cover is presented at the root, decoupled
  from which folder screen requested it, so the browsing context was lost.
- **Fix.** `DictationViewModel.init` gains a `folderPath` argument (default `[]`), so a fresh session
  files its thought there; a resuming note still overrides it with the folder it already lives in. The
  record/new-thought actions carry the current folder path (the folder screen and note page both know
  it); the root captures it at tap time (`newThoughtFolderPath`) and hands it to the dictation model, so
  the recorded thought lands in the folder the user was browsing. Hands-free entry points (Siri/CarPlay)
  keep passing `[]` (no folder context). Seam tests prove creating from path `[X]` yields a thought whose
  `folderPath` is `[X]`, and the default still files at the root.
- **Learning.** When a "create" action is reachable from a context that has a location (a folder, a
  project, a scope), thread that location into the create path so the new artifact lands where the user
  is - do not default to the root and force a move. If the create is decoupled from its trigger (a
  root-presented sheet), capture the context at trigger time and carry it through.
