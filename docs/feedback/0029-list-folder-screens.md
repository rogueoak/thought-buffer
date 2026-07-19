# Feedback 0029 - List and folder screen fixes

## Source

A batch of UX reports on the redesigned Thoughts screens (spec 0026 top-level folders + aliases):
a stale sort control, a missing search in the move-into-folder picker, a missing "move into" action
on folders, list padding, and (for the third time) a search field that drops focus while typing.

## Symptoms

2. **Sort control on the home page is meaningless.** The top-level screen is FOLDERS ONLY - the two
   alias folders (All Thoughts / Recents) plus the user's folders. A sort menu on that screen has
   nothing thought-ordered to sort (folders show A-Z; the aliases define their own order), so the
   affordance only confuses.
3. **No search in the "Move thoughts here" drawer.** `MoveThoughtsIntoFolderSheet` (the multi-select
   move picker) listed every candidate thought with no way to filter, so finding a thought in a long
   list meant scrolling.
4. **No folder "Move into" action.** A folder had no way to pull existing thoughts into it except the
   empty-state CTA - once a folder had one thought, the "Move thoughts here" action vanished. There was
   no such action in the folder screen's "..." menu, nor on the top-level folder rows beside Rename.
7. **Too much padding under the title.** Even after feedback 0026's tightening, the gap between the
   scrolling title and the first list row read looser than the Notes app.
8. **Search field STILL drops focus while typing (third attempt).** Feedback 0024 hoisted the field to a
   stable outer node; feedback 0026 pinned `.id("stream-bottom-stack")` on the bottom stack. The field
   STILL lost first responder as the list content changed while typing.

## Root causes

- **2 (sort):** the sort `ToolbarItem` was carried over from spec 0010's interleaved folders-and-thoughts
  list, where thoughts sat at the top level. Spec 0026 removed loose top-level thoughts, so the control
  outlived its purpose. The persisted `sortOrder` is still meaningful INSIDE a folder and for the
  swipe-to-play queue order, so only the top-level affordance is dead - not the state.
- **3 (move-picker search):** the picker never had a filter; it predates this report.
- **4 (folder move-into):** the batch move path (`feed.move(_ thoughts:to:)`) and the
  `MoveThoughtsIntoFolderSheet` already existed (feedback 0026 item 6), but were reachable only from a
  user folder's EMPTY-state CTA. Nothing exposed the same sheet on a non-empty folder.
- **7 (padding):** `StreamListTitleRow` used `top: x1 / bottom: x1` insets and `unifiedList()` reserved
  a `x2` top content margin. Both still read looser than Notes.
- **8 (focus, ROOT CAUSE):** the `.safeAreaInset(edge: .bottom)` that hosts the search `TextField` was
  attached to `switchingContent(...)`, whose body returned a DIFFERENT `List` view per `FolderScreenState`
  (`foldersList` / `searchResultsList` on the top level; `normalContent` / `thoughtList(searchResults)` in
  a folder). Typing the first character flips `.normal` -> `.searchResults`, which swaps one `List`
  instance for a structurally different one. SwiftUI diffs the two branches as different view identities,
  tears down the old content subtree, and - because the `.safeAreaInset` is a modifier ON that switching
  node - re-lays-out the inset that hosts the field. A stable `.id` on the bottom STACK is not enough: the
  stack lives inside an inset whose HOST node is being rebuilt when the primary content branch swaps, so
  first responder is resigned. This is view-IDENTITY churn, not a missing id. Every subsequent keystroke
  that re-crosses a state boundary (results <-> no-matches, or back to normal on clear) repeats it.

## Fixes

2. Removed the sort `ToolbarItem` (the `arrow.up.arrow.down` menu) from `TopLevelFoldersView`. The
   `sortOrder` binding stays - `FolderThoughtsView` still sorts a folder's thoughts, and the top-level
   swipe-to-play queues (`folderQueue` / `aliasQueue`) still order by it - so no state is orphaned. The
   persisted `settings.noteSortOrder` tag is untouched.
3. Added a search field at the top of `MoveThoughtsIntoFolderSheet` that filters the candidate list live
   by title/text, reusing `ThoughtSearch.results(in:query:)` (the SAME pure matcher the global search uses -
   no duplicated matching rules). Multi-select selections are stable across filtering: `selected` is a
   `Set<UUID>` keyed on id, independent of which rows are currently shown, so filtering never drops a
   selection and a re-shown row reflects its prior checkmark.
4. Added "Move thoughts here" in TWO places, both wired to the SAME `MoveThoughtsIntoFolderSheet` +
   `feed.move(_ thoughts:to:)` batch path the empty-state action uses:
   a. `FolderThoughtsView`'s nav-bar "..." menu (user folders only, beside Rename / Delete).
   b. `TopLevelFoldersView`'s folder rows - a trailing swipe action and a context-menu item, right beside
      Rename. The candidate filter (exclude thoughts already in that folder) is the sheet's own
      `candidates` computed property, so it stays consistent across every entry point.
7. Tightened the header further: `StreamListTitleRow` bottom inset dropped to `x0` (keeping `top: x1` so
   the title clears the toolbar), and `unifiedList()`'s top content margin dropped from `x2` to `x1`, so
   the first row sits close under the title. Consistent across both list screens and the search results
   (single-sourced in `StreamListTitleRow` + `unifiedList()`), and the title still scrolls with the list.
8. Made each list screen host ONE PERSISTENT `List` whose ROWS change with state, instead of swapping
   between two distinct `List` views. `switchingContent` no longer returns a different `List` per state:
   `.normal`, `.searchResults`, and `.noMatches` all render through ONE `List` (the normal rows, the
   result rows, or a single "no matches" row), so the content subtree that HOSTS the `.safeAreaInset` (and
   its search `TextField`) is never torn down as the query changes - only the List's child rows diff. The
   `.emptyStore` state stays a separate centered CTA, but it has no search field (nothing to search) and
   so no focus to lose; the transition into/out of it happens only when the store goes from zero thoughts
   to some, never mid-typing. The `TextField` instance is therefore stable across (i) the first keystroke,
   (ii) every later keystroke, (iii) the results <-> no-matches transition, and (iv) clearing the query.
   The `.id("stream-bottom-stack")` and the stable outer node (feedback 0024/0026) are kept as belt-and-
   braces, but the load-bearing change is that the field's host `List` is now ONE instance.

## Why the field instance is now stable (item 8)

SwiftUI keeps a view's backing store (and a hosted `UITextField`'s first responder) alive only while the
view's IDENTITY is stable across a body re-evaluation. The previous structure gave the field's host two
identities - the `List` under `.normal` and the different `List` under `.searchResults` - and SwiftUI
cannot know they are "the same" list, so it destroyed one and created the other on the state flip, taking
the inset's field with it. By rendering a SINGLE `List` whose ROWS vary, the host identity is constant:
SwiftUI diffs rows in place (insert/remove/update cells) and never rebuilds the List node, so the
`.safeAreaInset` and its `TextField` are never re-created. The pure state seam
(`FolderScreenState.contentUsesList`) documents which states share that one List, and a unit test pins it
so a future refactor that reintroduces a second List for a searching state fails in CI.

## Learning

A stable `.id` on a subview cannot save a first responder if an ANCESTOR that hosts it is swapped for a
different view identity. When SwiftUI focus is lost on a content change, look one level UP from the field:
if the branch CONTAINING the field's host (here a `.safeAreaInset` on a switched `List`) is itself being
replaced by a structurally different branch, no id on the field fixes it - the host must be ONE persistent
instance whose DATA changes, not two alternate views the state picks between. Prefer "one view, changing
data" over "pick one of N views" for any subtree that owns first-responder or other imperative UIKit state.

## Testing

- Full suite green on iPhone 17 Pro; build warning-free. (Final count in the PR.)
- New `FolderScreenState.contentUsesList` seam is unit-tested (`BottomBarLayoutTests`): normal / results /
  no-matches use the one persistent List, empty-store does not.
- The live search-field FOCUS retention, header spacing, the move-picker filter UI, and the folder
  move-into affordances are device/simulator-verifiable (SwiftUI first-responder retention and layout are
  not exercised by unit tests).

## Acceptance (device-verify)

- The top-level screen has no sort control; a folder screen still does, and it re-sorts the folder's list.
- The "Move thoughts here" drawer has a search field that filters candidates live; selections persist as
  the filter changes.
- A folder's "..." menu offers "Move thoughts here"; a top-level folder row's swipe / context menu offers
  it beside Rename. Both open the same picker and file the chosen thoughts in.
- The first list row sits close under the title (Notes-app tight), on both the top-level and folder
  screens, and the title scrolls with the list.
- Typing several characters in the search field keeps focus the whole time - through the first keystroke,
  every later keystroke, the no-matches state, and clearing the query. The record / new-thought buttons
  still work.
