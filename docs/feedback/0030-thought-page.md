# 0030 - Thought page polish

Four fixes to the single-thought (note) detail page, reported together.

## Item 5 - Anchor the play affordance at the bottom, floating with the search bar

**Symptom.** The "Play recording" button was still rendered inline in the note body (under the
title, above the text). A prior change (feedback 0027) moved the PLAYING transport (`BottomPlayer`)
into the detail's bottom stack, but the button that STARTS playback stayed in the content. The user
wanted it anchored at the bottom, floating with the find/search bar, like the other screens.

**Root cause.** `ThoughtDetailView` drew `playButton` inside the scrolling `VStack` body
(`if thought.hasAudio { playButton }`), separate from `detailBottomStack` where the shared player
lives. So the start affordance and the transport lived in two different places.

**Fix.** Removed the inline `playButton` from the note body. `detailBottomStack` now shows it ABOVE
the `BottomPlayer`, gated on `showsBottomPlayer && thought.hasAudio && !isThisThoughtLoaded`: an
audio thought that is not yet loaded shows a full-width "Play recording" pill; tapping it starts the
thought on the SAME shared `ThoughtPlaybackController`, which surfaces the existing `BottomPlayer`
transport (play/pause, scrubber, +/-15s) in the same inset. Once loaded, `BottomPlayer` renders and
the start pill drops away, so the two never overlap. A text-only thought has no audio, so no play
affordance shows. No second player, no second controller - the same shared controller and the
existing `BottomPlayer` as before.

**Placement decision.** The play affordance sits in `detailBottomStack` ABOVE the `BottomPlayer`
and above the find/search bar, in the bottom `.safeAreaInset`, gated on the SINGLE container decision
`StreamContainer.detailHostsBottomPlayer` (`showsBottomPlayer`): TRUE on the compact stack (the pushed
detail owns its inset), FALSE in the iPad split detail column (the player is lifted above all columns,
so neither the start pill nor the player render there - no double-render).

## Item 6 - Gear icon always rightmost

**Symptom.** On the list / folder screens the gear (settings) is the right-most trailing item; on a
note it was second from the right (the "..." menu was right-most). Inconsistent.

**Root cause.** In `ThoughtDetailView`'s trailing toolbar the gear `ToolbarItem` was declared BEFORE
the "..." menu. `.topBarTrailing` items lay out left-to-right in declaration order, so the last-declared
item is right-most - the "..." menu.

**Fix.** Reordered so the gear (Settings) `ToolbarItem` is declared LAST, after the "..." menu. The
gear is now right-most, matching `TopLevelFoldersView` and `FolderThoughtsView`.

## Item 9 - Preserve the search query into the thought and auto-focus the first hit

**Symptom.** Opening a thought from an active search dropped the query. The user expected the search
criteria to carry into the thought and auto-focus the first hit.

**Root cause.** The global search query was not threaded into `ThoughtDetailView`, so the in-note
find started empty on open.

**Fix.** Added an `initialFindQuery` parameter to `ThoughtDetailView`. `StreamListView.detailView`
passes the active `searchQuery` (only where the detail hosts its own find surface, `enablesFind`; the
split detail column defers to the lifted global bar and passes nothing). On appear, when the carried
query is non-empty, the view seeds `findQuery` with it, which drives the existing `refreshFind`
(rebuilding the navigator to the FIRST match) and, via the `currentMatch` observer, scrolls that hit
into view - identical to typing the query into the in-note field. An empty query (a thought opened
NOT from a search) does nothing. Next/prev + highlight are unchanged. The pure seam
`ThoughtFind.firstMatch(title:paragraphs:query:)` (title first, then paragraphs; nil for no hit /
empty query) is unit-tested in `ThoughtFindTests`.

## Item 10 - In-note match counter needs a background

**Symptom.** The "N of M" match counter floated over the content with no background and was hard to
read.

**Root cause.** `findNavigationControls` was a bare `HStack` in the bottom bar's trailing slot with
no surface behind it, so the count sat directly on whatever content scrolled behind the bar.

**Fix.** Wrapped `findNavigationControls` (the count + prev/next chevrons) in the shared
`BottomBarButtonGroup` (Canopy surface + border + capsule + shadow), so the group reads as part of
the find-bar with a solid background, matching the search field's pill beside it. The count text uses
`CanopyColor.text` (from `textSubtle`) and a monospaced digit for legibility.

## Learning

The two items that generalize past this page are captured in `overview/learnings.md`: a floating
control (a start-playback button, a counter) belongs in the shared bottom stack / bar group that
already carries a background, not layered over scrolling content; and threading an existing, active UI
state (a search query) into a pushed detail so the detail resumes that state is a one-parameter,
apply-once-on-appear seam, tested at the pure "first hit" boundary rather than in view code.
