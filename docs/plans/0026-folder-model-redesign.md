# Plan 0026 - Folder model redesign (top-level folders + All/Recents aliases)

Source spec: `docs/specs/0026-folder-model-redesign.md`.

## Model changes (pure, tested)

New pure seam `TopLevelFolders` (ViewModels), UI-free (no SwiftUI import), so it is unit-testable
and reusable:
- `AliasFolder` enum: `.allThoughts`, `.recents`. Cannot be renamed/deleted.
- `allThoughts(_:sorted:)` - every thought flat, honoring `ThoughtSortOrder`.
- `recents(_:limit:)` - the N most recent by `createdAt`, newest first (default limit 10).
- `topLevelFolderNames(childFolderNames:)` - the user folders at root (just passes through the
  store's top-level names; kept as a seam for symmetry/testability).
- `folderThoughts(_:folder:sorted:)` - a user folder's thoughts FLATTENED over any legacy subtree
  (thought's `folderPath` has the folder name as its FIRST component), honoring sort. This flattens
  old nesting so legacy data still surfaces.
- `uncategorized(_:sorted:)` - thoughts at the store root (empty `folderPath`).

New pure seam `NewThoughtPlacement`:
- `folderPath(browsingFolder:)` -> inside a user folder returns `[folderName]`; at top level / an
  alias returns `[]` (uncategorized). Tested.

## Route / navigation

`StreamRoute` gains a top-level-vs-folder distinction. The top level renders a NEW
`TopLevelFoldersView` (folders only: two alias rows + user folder rows, title as first list row).
A user folder / alias opens a NEW `FolderThoughtsView` (flat thought list, title as first list row).
`FolderContentsView` (interleaving) is retired for the redesign; its reusable pieces
(`StreamBottomStack`, rows, dialogs, search projection) are kept.

Routes:
- `.folder([String])` - a user folder (path is `[name]`, one level).
- `.alias(AliasFolder)` - All Thoughts or Recents.
- `.thought`, `.newThought` - unchanged.

## Title in the list

Title becomes the first scrolling row of each `List` (a header row), not the fixed
below-the-toolbar `.streamListTitle`. Keep the search field on a stable node (feedback 0024) so the
focus-stability test still holds: the bottom stack stays on the stable outer view; only the list
content (which now includes the title header row) switches.

## Tighter rows

`rowInsets()` top/bottom drops from `x1_5` (6) to `x0_5` (2) so the list reads dense; horizontal
insets and card internal padding unchanged so tap targets/legibility hold.

## Storage / migration

No serialization change. `createFolder` offered only at top level. Move-to-folder targets top-level
folders only. Legacy nested thoughts surface flattened under their first-component folder.

## Tests

`TopLevelFoldersTests`, `NewThoughtPlacementTests`; keep feedback-0024 focus test and spec-0022
split test green. Full suite on iPhone 17.
