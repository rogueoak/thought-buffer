# Plan 0010 - Folders and sorting

Source: spec `docs/specs/0010-folders.md`. Built in two PRs.

## PR A - folder-aware storage (this plan's focus; no UI change)

1. **Model.** Add `Note.folderPath: [String]` (default `[]`), NOT serialized to Markdown. Set on load
   from the file's relative directory; consumed on save to place the file. Add a `Note.sanitizedFolderName`
   helper (strip `/`, `\`, leading dots, trim) so a name can't escape the tree.
   Files: `Models/Note.swift`.
2. **Sort order type.** Add `NoteSortOrder` enum (`newest`, `oldest`, `titleAZ`, `titleZA`) with a pure
   `sort(_:)` over `[Note]` and a stable secondary key. Files: new `Models/NoteSortOrder.swift`.
3. **Local store tree-awareness.** `NoteStore`:
   - `loadAll()` walks recursively (enumerator), tagging each note's `folderPath` from its relative dir.
   - private `locateFile(id:)` scans the tree for `<id>.md`; `audioURL/saveAudio/deleteAudio/audioExists`
     use it (falling back to root when absent).
   - `save(note)` writes to `directory/<folderPath>/<id>.md`, creating dirs, and relocates an existing
     `<id>.md` + `<id>.m4a` when the folder changed.
   - `delete(id:)` locates and removes the file + sibling audio anywhere in the tree.
   - folder ops: `folders(at:)`, `createFolder(named:at:)`, `renameFolder(at:to:)`, `deleteFolder(at:)`.
   Files: `Storage/NoteStore.swift`, `Storage/NoteStoring.swift` (protocol additions with safe defaults).
4. **iCloud store.** Mirror the tree-awareness in `ICloudNoteStore`, wrapping each walk/move/cascade in
   `NSFileCoordinator`. Files: `Storage/ICloudNoteStore.swift`.
5. **Save ordering.** `DictationViewModel.saveCurrentNote` saves the note file before adopting the
   recording, so the `.m4a` lands beside the `.md` in the note's folder. Files: `ViewModels/DictationViewModel.swift`.
6. **Tests.** `NoteStore` folder round-trip, move relocates md+m4a, delete-cascade, rename, audio in
   subfolder resolves; `ICloudNoteStore` same against a temp dir; `NoteSortOrder` ordering; `Note`
   folder not in Markdown. Verify full suite green before commit.

## PR B - UI (separate plan/PR)

Folder navigation stack on the Thoughts screen, folder create/rename/delete, move-to-folder picker,
and the persisted sort menu (`SettingsStoring.noteSortOrder`). Wire the driver/feed to load a folder
path and re-sort live. Detailed when PR A merges.

## Verification

Each store change is proven by unit tests against a temp directory (no device needed for storage).
UI (PR B) is device-verified per repo convention, with the sort/move logic kept pure where possible.
