# Feedback 0025 - Unified Notes-app-style list (one container for the whole list)

## Source

Device feedback from Matthew (2026-07-19) on the top-level and folder lists:

> You still have thoughts and folders as separate cards. Can you make them a unified list? The content of
> the card is good but it should feel more like the Notes app. I do still like the content of each row and
> the border/background should be for the whole list, not just per folder or thought.

## Change

Convert the per-row CARD styling into a UNIFIED, Notes-app-style grouped list. The surface background,
border, and rounded corners move OFF each individual row and onto the WHOLE list as ONE inset rounded
container. Rows inside are separated by hairline Canopy-border dividers instead of gaps between
free-floating cards. Each row's CONTENT is unchanged (thought: title / snippet / metadata / duration /
play affordance; folder: glyph / name / count / chevron; the alias smart-folder row), and every swipe
action, context menu, and tap target is preserved.

- **Row chrome removed.** `ThoughtCard`, `FolderRow`, and `AliasFolderRow` drop their per-row
  `background(surface)` + `clipShape(RoundedRectangle)` + `overlay(stroke(border))`. They now render only
  the content + internal `x4` padding.
- **List container added.** Both list screens and the search-results list wrap their rows in a single
  `Section` and apply a new `unifiedList()` modifier (`.listStyle(.insetGrouped)` +
  `scrollContentBackground(.hidden)`), so the Canopy `bg` shows through around ONE inset rounded card that
  holds all the rows. A new `unifiedRow()` modifier gives each row the shared `surface` fill
  (`listRowBackground`), a `border`-tinted hairline divider (`listRowSeparatorTint`), and a content-inset
  separator, replacing the old `tightRowInsets()`.
- **Title above the card.** The scroll-away title (`StreamListTitleRow`, spec 0026) stays the first row and
  sits ABOVE the unified card (Notes-app style): its list-row horizontal inset is zeroed so the grouped
  section margin governs alignment and it lines up with the card's leading text edge on any device.
- **Consistent everywhere.** Applied to the top-level folders list, the folder-thoughts list, and the flat
  search-results list, so it holds in the iPad split content column and the compact stack alike. The inline
  empty-folder message is a single row inside the same unified card.

No hardcoded colors: the container fill, dividers, and text all read Canopy tokens (`surface`, `border`,
`bg`, `text`, `textMuted`, ...). ASCII-only.

## Acceptance

- The top-level folders list, a folder's thoughts list, and a search-results list each render as ONE inset
  rounded card (surface fill + border) with hairline dividers between rows, not a stack of separate bordered
  cards.
- Each row keeps its exact content and its affordances: thought rows keep the leading Play/Move swipe, the
  trailing Delete swipe, and the long-press context menu; folder rows keep Rename/Delete swipe + context
  menu and the leading play-queue swipe; alias rows keep the leading play-queue swipe.
- The screen title scrolls with the list and sits above the card, aligned to the card's leading text edge.
- Empty states (empty store CTA, no-search-matches, inline empty-folder message) still render correctly.
- Holds in the iPad split (content column) and the compact stack.
- Full test suite green on iPhone 17; no new build warnings.

## Device-verify

The grouping is visual, so verify on device:

- One border/background wraps the whole list (top level, inside a folder, and a search) - not per row.
- Dividers are hairline Canopy-border and inset to the row content, Notes-app style.
- Title sits above the card and aligns with the row content's leading edge; it still scrolls away.
- Swipe-to-play, swipe-to-move, swipe-to-delete, and the context menus all still fire from within the card.
- Light and dark mode both read correctly (surface / border / bg adapt).
- iPad split content column and compact iPhone stack both show the unified card.
