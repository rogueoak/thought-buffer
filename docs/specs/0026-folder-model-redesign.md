# Spec 0026 - Folder model redesign (top-level folders + All/Recents aliases)

## Motivation

Device feedback from Matthew (2026-07-19):

> I've changed my mind on nesting folders and having folders and thoughts at the
> same level. The top level should be exclusively folders and then within them is
> thoughts. There should be a couple alias folders at the top: All Thoughts which
> opens a list of everything; Recents which opens a list of the most recent
> thoughts. When you make a new thought, it doesn't get categorized, it just goes
> under recents / all.

This supersedes spec 0010's nested folders + interleaved folders-and-thoughts, and
spec 0021's list layout. Confirmed decisions:
- New thought while INSIDE a user folder -> filed in that folder (contextual,
  preserving feedback 0021's contextual creation). From the top level / All /
  Recents -> UNCATEGORIZED.
- **Recents = the last 10 thoughts, newest first.**

## The model

- **Top level = folders ONLY.** No thoughts and no folder rows interleaved with
  thoughts at the top level. The top level is a list of folders:
  - Two ALIAS (virtual/smart) folders pinned at the top, visually distinct:
    - **All Thoughts** - opens a flat list of every thought (any folder +
      uncategorized), honoring the sort order.
    - **Recents** - opens the 10 most recent thoughts by createdAt, newest first.
  - Then the user's folders (created/renamed/deleted as today, but only at the top
    level).
- **One level deep - no nesting.** A folder opens a flat list of its thoughts. There
  are no sub-folders. To keep existing data safe, a folder shows ALL thoughts in its
  subtree flattened (so any thoughts that lived in an old nested folder still appear
  under their top-level folder), but new sub-folders cannot be created.
- **Uncategorized thoughts** = thoughts not in any user folder (the `.md` files at
  the store root). They appear in All Thoughts and Recents, but in no user folder.
- **New thought placement:** inside a user folder -> that folder; from top level /
  All / Recents -> uncategorized (root). This keeps contextual creation where it
  makes sense and matches "it just goes under recents / all" for the default case.

## The aliases are virtual

All Thoughts and Recents are COMPUTED views over the loaded thoughts, not real
directories on disk (do not create `.md`/folders for them). Factor them as pure,
testable projections: `allThoughts(sorted:)` and `recents(limit: 10)`. Deleting is
disabled on the aliases; they cannot be renamed.

## Folded-in list polish (feedback items from the same round)

1. **Title scrolls WITH the list.** The screen title ("Thoughts" at the top level,
   or the folder name) becomes the first element of the SCROLLABLE list (a list
   header row / section header that scrolls away), not a fixed title pinned below
   the toolbar. Applies to the top-level and folder screens. (Supersedes feedback
   0016/0020's fixed below-the-toolbar title placement.)
2. **Tighter rows.** Remove the extra inter-row padding so the list reads as a
   compact, dense list rather than bulky cards. Reduce the row insets/vertical
   spacing (use a tighter Canopy spacing token); keep tap targets adequate and the
   metadata legible.

## Storage / migration

- No serialization change: thoughts stay `<id>.md`; folders stay directories; the
  root holds uncategorized thoughts. The redesign is a VIEW/model-projection change
  over the same storage.
- `createFolder` is offered only at the top level now. `move-to-folder` moves an
  uncategorized thought into a folder or between folders (targets are top-level
  folders). Existing deeper directories keep working (their thoughts surface,
  flattened, under the top-level folder); the UI just stops creating new nesting.
- Existing root thoughts become "uncategorized" automatically (they already live at
  root) - they now show under All/Recents, which is correct.

## Non-goals

- No tags/multi-folder membership; a thought is uncategorized or in exactly one
  folder.
- No re-introduction of nesting or top-level thoughts.
- No change to search (spec 0021 global + spec 0025 in-thought find) beyond the list
  restructure; All Thoughts is not "search".

## Acceptance

- The top level shows All Thoughts + Recents + user folders, and NO loose thoughts.
- All Thoughts opens every thought (flat, sorted); Recents opens the last 10 newest
  first; both are pure and unit-tested.
- Opening a user folder shows its thoughts (flattened over any legacy subtree).
- A new thought created inside a folder lands in that folder; created from top
  level / All / Recents it is uncategorized (root) and appears in All + Recents.
- The title is the first scrolling element of the list (scrolls away), not a fixed
  header.
- Rows are visibly tighter (reduced inter-row padding) while staying legible and
  tappable.
- Storage format unchanged; existing thoughts/folders still load. Full suite green;
  the alias projections + placement logic are unit-tested.
