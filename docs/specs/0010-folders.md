# 0010 - Folders and sorting

## Problem

The Thoughts list is one flat, newest-first stream. As notes pile up there is no way to group
related thoughts ("Work", "Book ideas", "Groceries") or to reorder the list, so finding an older
thought means scrolling the whole pile. The app already stores notes as real Markdown files the user
owns, so grouping should be real folders on disk (visible in the Files app / iCloud Drive), not a
hidden tag.

## Outcome

- **Folders you can nest.** Create a folder from the Thoughts toolbar; open it to see its notes and
  subfolders; create a folder inside a folder. A breadcrumb / back navigation walks the tree.
- **Move thoughts into folders.** A note has a "Move to folder" action (swipe or context menu) that
  opens a folder picker with "New folder...", the folder tree, and "Move to top level". Notes are
  created at the top level and filed afterward.
- **Delete a folder deletes its contents.** Deleting a folder removes the folder and everything inside
  it - notes, their recordings, and subfolders - after a confirming prompt (it is destructive).
- **Rename a folder.** A folder can be renamed; its notes move with it (they live inside it on disk).
- **Sort.** The list (top level and inside any folder) sorts by a chosen order, persisted across
  launches: newest-oldest (default), oldest-newest, title A-Z, title Z-A. Folders sort among notes by
  the same key (a folder's "date" is its most recent note; its "title" is its name).
- **Real files.** A note in a folder lives at `Documents/ThoughtStream/<folder>/.../<id>.md` with its
  `<id>.m4a` beside it, so the grouping is visible and portable in Files / iCloud Drive. The Markdown
  file format is unchanged - a note's folder is its location, not a frontmatter field.

## Scope

**In:** nested folders on disk (local + iCloud), folder create / rename / delete-cascade, move a note
(and its recording) between folders, in-app folder navigation, a persisted global sort order, and the
CarPlay recordings browser continuing to work (it lists all recorded notes regardless of folder).

**Out:** moving whole folders into other folders via UI (rename only, in this pass), multi-select
move, per-folder sort overrides, folder colours/icons, and sharing a folder. Swipe-to-play a folder
(the queue) is spec 0011, which builds on the folder model this spec establishes.

## Approach

Split into two PRs under this spec:

### PR A - folder-aware storage (no UI change)

- **`Note.folderPath: [String]`** - the ordered folder names containing the note (empty = top level).
  It is a STORAGE LOCATION, derived on load from where the file sits and consumed on save to place the
  file; it is NOT serialized into the Markdown (the file format stays byte-identical, so old files and
  other apps are unaffected). Folder names are sanitized (no path separators) so a name can never
  escape the tree.
- **`NoteStore` / `ICloudNoteStore` become tree-aware.** `loadAll()` walks the directory recursively,
  tagging each note with the relative folder path of its file. `save(note)` writes to
  `directory/<folderPath>/<id>.md`, creating intermediate directories, and RELOCATES an existing
  `<id>.md` (and its `<id>.m4a`) when the note's folder changed - so saving a note with a new
  `folderPath` is the move. Id-only operations (`delete`, `audioURL`, `audioExists`, `saveAudio`) find
  a note's file by scanning the tree for `<id>.md`, keeping the `NoteStoring` protocol id-only (no
  ripple into the resolver / playback controller). `DictationViewModel` saves the note file before
  adopting its recording so the recording lands in the same directory. `ICloudNoteStore` wraps every
  new directory walk, move, and cascade in `NSFileCoordinator`, exactly as it does today.
- **Folder operations on the store:** `folders(in:)` (list child folders at a path), `createFolder`,
  `renameFolder`, `deleteFolder` (recursive, deleting notes + recordings). All coordinated on iCloud.
- Fully unit-tested against a temp directory before any UI.

### PR B - folder UI, move, and sort

- **Navigation.** The Thoughts screen shows, for the current folder path, its child folders (as folder
  rows) then its notes, sorted by the chosen key. Tapping a folder pushes into it; a back/breadcrumb
  returns. Top level is the root.
- **Folder create / rename / delete** from the toolbar and a folder row's context menu; delete confirms
  and cascades.
- **Move a note** via a leading-swipe / context "Move to folder" that presents a folder-tree picker
  (with "New folder..." and "Move to top level"); moving re-saves the note with the new `folderPath`.
- **Sort control** in the toolbar (a menu) writing the chosen `NoteSortOrder` to `SettingsStoring`
  (persisted); the list and folders re-sort live. Applies everywhere.

## Acceptance

- [ ] A note saved with a `folderPath` writes to that subdirectory; `loadAll` reads it back with the
      same `folderPath`; the Markdown bytes are unchanged from a top-level note.
- [ ] Saving a note with a changed `folderPath` moves its `.md` and `.m4a` and leaves nothing behind.
- [ ] `deleteFolder` removes the folder, its notes, their recordings, and its subfolders.
- [ ] `renameFolder` keeps the notes (now under the new name).
- [ ] Recorded note filed into a folder still plays (audio resolves in the new directory), and the
      CarPlay recordings browser still lists it.
- [ ] Sort order persists across launch and reorders both notes and folders by newest/oldest/title.
- [ ] Nested create/navigate/delete works to at least two levels.
- [ ] Full suite green; the iCloud store's tree operations are covered against a temp directory.
