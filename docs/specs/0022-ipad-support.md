# Spec 0022 - iPad support

## Motivation

Device feedback from Matthew (2026-07-19):

> The app should work on iPad.

Make Thought Stream a first-class iPad app, not a stretched iPhone app.

## Depends on

The bottom-bar redesign (spec 0021) changes the primary navigation surface, and the
iPad layout is built around it. Sequence AFTER 0021 so the iPad adaptation targets
the final navigation, not the old one.

## Scope

1. **Adaptive navigation.** On regular width (iPad, and iPhone landscape where
   appropriate) present a `NavigationSplitView`: folders / top-level list in the
   sidebar, the selected folder's notes in the content column, and the note detail
   in the detail column. On compact width, keep today's `NavigationStack` behavior.
   Preserve the existing `StreamRoute` model behind whichever container is active.

2. **Layout that uses the space.** Multi-column or wider note cards where it reads
   well; the centered empty-state CTA (spec 0021) sizes sensibly on a large canvas;
   the bottom bar's search field spans appropriately without looking stretched.

3. **Targets / project.** Enable the iPad device family in project.yml (XcodeGen),
   set correct orientations, and verify the app builds and runs on an iPad
   simulator. Ensure the launch cover (spec 0012), share sheet (spec 0017), and
   dictation UI all lay out correctly on iPad.

4. **Regression safety.** iPhone layout and behavior are unchanged on compact width.

## Required restructure carried from the 0021 review

The search + bottom-bar redesign (0021) owns bottom-bar/search/undo state PER
folder-screen instance and vends the shake `UndoManager` from a first-responder host
attached to the single root `NavigationStack`. That works only because a
`NavigationStack` shows one screen at a time. Under this milestone's
`NavigationSplitView` these become bugs that MUST be handled here (flagged by the
0021 architect review, not defects in 0021 itself):

- **Lift bottom-bar + search ownership above the navigation container.** With a
  sidebar column and a content column both showing `FolderContentsView`
  simultaneously, each would render its own `BottomBar` bound to the one shared
  `searchQuery` and the same global flat results - two search fields fighting one
  state. Move the bottom bar, the search query, and the results projection up to the
  split container so there is a single search surface and one results list.
- **Re-home the `UndoManagerHost` first responder for split view.** First responder
  moves between columns and focused fields on iPad; the host must re-assert / re-home
  so Shake-to-Undo keeps reaching the deletion controller's manager regardless of
  which column is active (0021 fixes the re-assert-on-focus-change case; multi-column
  is this milestone's extension).
- **Extract any remaining per-screen affordance decisions into the pure layout seam**
  so both compact and split layouts drive one tested `BottomBarLayout`.

## Non-goals

- No iPad-specific features (no multi-note side-by-side editing, no pointer/keyboard
  shortcuts beyond what comes for free) in this milestone - just a correct,
  native-feeling adaptive layout.
- No Stage Manager / external-display specialization beyond standard adaptivity.

## Acceptance

- The app builds and runs on an iPad simulator and presents a split-view layout on
  regular width, with folders in a sidebar and note detail in its own column.
- Rotating and resizing (multitasking split) adapt without broken layout.
- Compact-width (iPhone) layout and behavior are unchanged; the full suite stays
  green.
- Any layout-decision logic that can be made pure (size-class -> container choice)
  is factored and unit-tested.
