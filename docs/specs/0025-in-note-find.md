# Spec 0025 - In-thought find (seek + highlight + skip matches)

## Motivation

Device feedback from Matthew (2026-07-19):

> Searching within a note should find the text that matches in the note and seek to
> the spot in the note and highlight it. If there are multiple matches, you should
> be able to skip between them.

Spec 0021 made the bottom-bar search GLOBAL everywhere and explicitly deferred
per-thought find. This spec makes search CONTEXTUAL: on a thought's detail screen the
search field finds within THAT thought (seek + highlight + skip), while on the list /
folder screens it stays the global finder from 0021.

## Scope

### 1. Contextual search field

- On the **thought detail** screen, the bottom-bar search field performs IN-THOUGHT
  find (this supersedes 0021's "note-detail search routes to global results").
- On **list / folder** screens, the search field stays GLOBAL (0021), unchanged.

### 2. Find matches (pure core)

A pure, unit-testable `ThoughtFind` (or similar) that, given the thought's title +
paragraphs and a query, returns the ordered list of match locations (paragraph index
+ character range within that paragraph; include the title as an addressable region).
Case-insensitive and diacritic-insensitive substring, matching `ThoughtSearch`'s
folding. Empty/whitespace query = no matches. Also exposes next/previous index
navigation over the match list (wrapping), and the "N of M" count - all pure and
tested.

### 3. Seek + highlight (UI)

- **Highlight** every match in the rendered thought text (an `AttributedString`
  background/emphasis on the matched ranges), with the CURRENT match emphasized more
  strongly than the others. Canopy tokens for the highlight colors.
- **Seek**: scroll the current match into view using `ScrollViewReader` (anchor each
  paragraph / match region by a stable id). Changing the current match scrolls to it.
- **Skip between matches**: previous / next controls (chevrons) plus the "N of M"
  count in or beside the search field while a find is active. Next past the last
  wraps to the first (and previous from the first wraps to the last), or clamps -
  pick one and be consistent; document it.
- Clearing the query removes all highlights and the prev/next/count affordance.

### 4. Interaction

- Editing a thought and finding are mutually exclusive (do not show the find bar +
  highlights while the body/title editor is active), consistent with the existing
  edit-mode gating.
- Find state resets when leaving the thought.

## Non-goals

- No find-and-replace, no regex, no cross-thought find from the detail screen (that's
  the global search on the list screens).
- No highlight persistence after the query clears or the screen is left.

## Acceptance

- On a thought with the query appearing 3 times, the detail search field shows "1 of
  3", highlights all three (current one emphasized), and scrolls the current match
  into view; next/previous move through them (with the documented wrap/clamp).
- On the list/folder screens the search field still does global find (0021 unchanged).
- The pure `ThoughtFind` is unit-tested: title + body-paragraph matches, ordering,
  case/diacritic-insensitivity, no-match, next/previous navigation + count, empty
  query.
- Find and edit modes are mutually exclusive; find state clears on query-clear and on
  leaving the thought.
- Full suite green; new pure seam unit-tested.
