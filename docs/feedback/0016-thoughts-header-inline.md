# Feedback 0016 - Thoughts header inline with the toolbar buttons

## Source

Device feedback from Matthew (2026-07-19):

> Can you make the Thoughts header text be inline with the buttons on the right (mic
> and gear). It is currently below it.

## Observation

The top-level Thoughts screen uses a large navigation title (`.navigationTitle("Thoughts")`
with the default large display mode). iOS renders a large title on its OWN row BELOW the
navigation bar, so "Thoughts" sat under the trailing mic and gear buttons rather than beside
them. The user wants the title on the same horizontal row as the buttons (title left,
buttons right).

## Fix

Set the root screen's title to inline display mode so the title shares the navigation bar
with its toolbar items:

- In `StreamListView`, add `.navigationBarTitleDisplayMode(.inline)` to the root
  `FolderContentsView` (the `[]` path), alongside its existing `.navigationTitle("Thoughts")`.
- The mic and gear (and new-note, new-folder, sort) are already `topBarTrailing` /
  `topBarLeading` toolbar items on that same bar, so with the title inline they render on one
  row: "Thoughts" centered/left, buttons right, exactly as asked.
- The title keeps the standard inline navigation-title styling (the system headline the rest
  of the app's nav bars use), so it looks right at the inline size without a custom font
  override on the nav bar.

Only the top-level screen is touched; the pushed folder / note detail screens are unchanged.

## Acceptance

- On the Thoughts screen, "Thoughts" sits on the same row as the mic and gear buttons, not
  below them.
- The mic, gear, new-note, new-folder, and sort controls still work and stay on the bar.
- The pushed folder and note-detail screens are unaffected.
- Suite stays green (a nav-bar layout change is verified visually on device).
