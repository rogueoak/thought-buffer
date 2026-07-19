# Feedback 0024 - Keep the search field focused after the first keystroke

## Source

Device feedback from Matthew (2026-07-19) on the persistent bottom-bar search:

> When I search for a thought, I type the first letter and then the search box unfocuses and I have to
> refocus it. It should keep its focus.

## Root cause

The bottom bar (which hosts the search `TextField`) was rendered in a `.safeAreaInset(edge: .bottom)`
attached to the SAME view node whose content switched on `FolderScreenState`. In
`FolderContentsView.bodyContent` the whole body was one `Group { switch screenState { ... } }` with the
bottom stack pinned to it.

On the FIRST keystroke the query goes from empty to non-empty, so the resolved state flips from `.normal`
(the interleaved folder list) to `.searchResults` (the flat global results list). That flip swaps one
`List` for a different `List` inside the switched subtree. Because the `.safeAreaInset` bottom stack sat on
the same node as the switching content, SwiftUI tore down and rebuilt the modified subtree - including the
inset that hosts the search `TextField` - so the field lost first responder and the keyboard dropped after
one character. Every subsequent character then needed a manual refocus.

## Fix

- Split the folder screen body so the state-driven content (`switchingContent`: empty CTA / search results /
  no-matches / normal list) lives in ONE inner view, and pin its host identity with
  `.id("stream-folder-content")`. Only that inner content swaps on a state flip.
- Attach the outer chain - the background, the `.safeAreaInset` bottom stack (with the search field), the
  banners, the toolbar, the alerts - to the STABLE outer node, above the pinned content. The bottom bar is
  therefore ONE persistent instance across the empty->results transition, so the `TextField` is never
  recreated and keeps its focus / keyboard.
- The search field's identity is already stable: it is a single `TextField` in `BottomBar.searchField` with
  no `if`/conditional wrapping it (only the clear button appears/disappears, which does not change the
  field's identity), and `FolderScreenState.showsSearchField` stays TRUE across the empty->results flip (it
  is false only in the truly empty store), so the field never unmounts mid-search.
- The split-view lifted bar was already correct: its `StreamBottomStack` is composed OUTSIDE the columns in
  `splitView`'s own `.safeAreaInset`, so it was never on the switching content node. The bug was
  compact-stack only; the fix keeps both paths sharing the same `StreamBottomStack`.

## Testing

- Added `testSearchFieldStaysMountedAcrossFirstKeystrokeTransition` to `BottomBarLayoutTests`: it pins the
  pure precondition that the field stays mounted (`showsSearchField` stays true) as the state flips from
  `.normal` to `.searchResults` and to `.noMatches` on the first keystroke.
- The focus behavior itself is device-verifiable (SwiftUI first-responder retention is not exercised by unit
  tests); see acceptance below.
- Full suite green on iPhone 17 (657 tests, 0 failures), build warning-free.

## Acceptance (device-verify)

- On the list screen, tap the search field and type several characters in a row: focus and the keyboard
  stay up the whole time, no refocus needed after the first letter.
- The same holds on a folder screen (a pushed folder's list).
- Clearing the query with the clear (x) button returns to the normal list and keeps/returns focus sensibly.
- Searching a query that matches nothing (the "No matches" state) keeps the field focused so it can be
  edited or cleared.
- On the iPad lifted bar (regular width), typing keeps focus (this path was already correct and is
  unchanged).
