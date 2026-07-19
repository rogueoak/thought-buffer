# Feedback 0026 - List and folder UX fixes

## Source

A batch of UX reports on the redesigned Thoughts screens (spec 0026 top-level folders + aliases):
list header spacing, row alignment, search focus, folder rename/delete, an in-folder menu, and the
empty-state actions.

## Symptoms

1. **Header padding too large.** The scrolling section title ("Thoughts" at the top level, the folder
   name inside) sat with a wide gap above and below, and the list itself started far below the toolbar -
   not the tight, Notes-app rhythm.
2. **Alias icon misalignment.** On the top-level screen the "All Thoughts" / "Recents" alias rows used a
   32pt tinted icon tile, while the user-folder rows below used a bare `folder.fill` glyph with no fixed
   width. The two icons were different widths, so the row TEXT did not line up on one left edge.
3. **Search focus broken (two bugs).**
   a. Typing the FIRST letter in the bottom search field dropped focus, so every character after the
      first needed a re-tap.
   b. When a query matched nothing ("No matches"), the field appeared to become uneditable - the user
      was stuck and had to navigate away to change the query.
4. **Folder rename and delete did nothing.** Renaming or deleting a folder from the top-level screen had
   no visible effect.
5. **No in-folder folder menu.** Inside a folder there was no way to rename or delete THAT folder without
   backing out to the top-level screen.
6. **Empty state offered two actions.** An empty folder offered only Record and New thought, with no way
   to pull EXISTING thoughts into the folder.

## Root causes

- **1 (padding):** `StreamListTitleRow` used `top: x3 / bottom: x2` row insets, and `.insetGrouped`
  reserves a large default TOP content margin above the first row. Both were untouched by the redesign.
- **2 (alignment):** `FolderRow`'s `folder.fill` glyph had no `.frame(width:)`, so its intrinsic width
  (~20pt) was narrower than the alias tile's fixed `x8` (32pt); the `HStack` therefore placed the two
  rows' text at different x offsets.
- **3a (first keystroke):** the first character flips `FolderScreenState` from `.normal` to
  `.searchResults`, which swaps one `List` for another in the primary content. That relayout re-evaluates
  the `.safeAreaInset(edge: .bottom)` that hosts the search `TextField`; without a stable identity on the
  bottom stack, SwiftUI rebuilt the field and dropped first responder. (Feedback 0024 moved the field to a
  stable OUTER node, which was necessary but not sufficient after the spec 0026 redesign - the inset
  content itself still needed a pinned id.)
- **3b (no matches):** the state seam was already correct (`FolderScreenState.noMatches.showsSearchField`
  is true, so the field stays mounted). Once 3a is fixed, the field also stays FOCUSED across the
  normal -> results -> no-matches transitions, so the user can edit or clear the query in place.
- **4 (rename/delete):** the store, driver, and feed were all correct (proved by tests). The bug was in
  the top-level screen's alert buttons: `Button("Rename") { Task { await renameFolder() } }`, and
  `renameFolder()` read the target path from `activeDialog`. Tapping an alert button DISMISSES the alert,
  which fires the dialog binding's setter and clears `activeDialog` to nil. The `Task` runs on a LATER
  runloop tick, by which point `activeDialog` is already nil, so `guard case .renameFolder(path)? =
  activeDialog` failed and the rename/delete silently did nothing. (Create worked because it read the
  separate, surviving `folderNameField` state.)

## Fixes

1. Tightened `StreamListTitleRow` insets to `top: x1 / bottom: x1`, and added
   `.contentMargins(.top, x2, for: .scrollContent)` in the shared `unifiedList()` so the title sits close
   to the toolbar. Applies to both list screens and the search-results list (single-sourced).
2. Gave `FolderRow`'s glyph a fixed `.frame(width: x8)` matching the alias tile, so both rows' text align
   on one left edge (`x4 + x8 + x3`).
3. Pinned a stable `.id("stream-bottom-stack")` on the `StreamBottomStack` inside the bottom safe-area
   inset on both list screens, so the search `TextField` is the SAME instance across every content-state
   flip and keeps focus from the first keystroke through the no-matches state.
4. Capture the dialog payload (path, new name) SYNCHRONOUSLY in the alert button action, before spawning
   the async `Task`, and pass it into `renameFolder(at:to:)` / `deleteFolder(at:)`. No code path reads
   `activeDialog` after the dialog has dismissed.
5. Added an ellipsis ("...") menu to `FolderThoughtsView`'s nav bar (shown only for a user folder, not an
   alias) with "Rename folder" and "Delete folder", wired to the SAME `feed.renameFolder` /
   `feed.deleteFolder` store ops. Rename re-points navigation at the new name; delete pops back to the
   top-level screen (compact) or clears the split selection (iPad). Payload is captured synchronously,
   same as fix 4.
6. Added a third empty-state action, "Move thoughts here", to `FolderEmptyStateCTA` (optional, shown only
   inside a USER folder that could receive thoughts). It opens a new multi-select `MoveThoughtsIntoFolderSheet`
   listing every thought NOT already in the folder; the selected thoughts are re-filed into the folder via
   `feed.move`. **Decision:** the action is OMITTED in the root / All Thoughts / an alias empty state and in
   a truly empty store, where "move into this folder" is meaningless.

## Learning

When an alert (or any dismiss-on-tap presentation) button needs the payload of a per-presentation state
enum, READ that payload SYNCHRONOUSLY inside the button action - not inside a `Task`/async continuation
that the presentation's own dismissal binding will out-race by clearing the state first. Deferring the
read to a later runloop tick means the "which item was this dialog for" state is already gone. Capture the
value at tap time; act on the captured value. This generalizes the feedback 0018 un-stacked-alerts lesson:
un-stacking fixed presentation, but the payload READ still has to beat the dismissal.

## Testing

- Extended `FolderRenameDriverTests` with delete-through-the-feed (removes on disk + reloads),
  empty-path-is-a-no-op, and move-multiple-thoughts-into-a-folder tests (feedback 0026, items 4/5/6).
- `FolderScreenState` no-matches / field-stays-mounted seam is already unit-tested (`BottomBarLayoutTests`);
  the store-level rename/delete is already covered (`ThoughtStoreTests` / `ICloudThoughtStoreTests`).
- The header spacing, icon alignment, live search-field FOCUS retention, the "..." menu presentation, and
  the move picker are device/simulator-verifiable (SwiftUI first-responder retention and layout are not
  exercised by unit tests).
- Full suite green on iPhone 17 (704 tests, 0 failures), build warning-free.

## Acceptance (device-verify)

- The list title sits close to its rows and to the toolbar (Notes-app tight), on both the top-level and a
  folder screen.
- The "All Thoughts" / "Recents" / folder-row text all line up on one left edge.
- Typing several characters in the search field keeps focus the whole time (no refocus after letter one),
  and a no-match query keeps the field focused so it can be edited or cleared in place.
- Rename and delete a folder from the top-level "..." / swipe / context menu - both take effect and the
  list updates.
- Inside a folder, the nav-bar "..." menu renames or deletes THAT folder; delete pops back to the top.
- An empty folder offers Move thoughts here / Record / New thought; Move opens a multi-select picker of
  existing thoughts and files the chosen ones into the folder.
