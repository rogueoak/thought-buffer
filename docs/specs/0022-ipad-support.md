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
