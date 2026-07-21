# Feedback 0032 - Bottom bar reads smaller than the top toolbar

## Symptom

The persistent bottom bar (the search field plus the trailing action buttons -
new-thought, record, resume) reads noticeably SMALLER than the top toolbar buttons on
the same page (gear, sort, folder-options, mic). They should feel like the same size.

## Root cause

The bottom bar sized itself with explicitly SMALL design tokens while the top toolbar
renders SF Symbols at SwiftUI's default toolbar sizing (which is larger on device):

- Search field: magnifier + clear glyphs and the field text at `sizeSm` (14pt), with
  `x2` (8pt) vertical padding - a short pill.
- `BottomBarIconButton` (new-thought / resume): `sizeLg` (18pt) glyph in an `x8`
  (32pt) frame.
- `BottomBarRecordButton`: `sizeBase` (16pt) mic in an `x8` (32pt) frame.

## Fix

Bump the bottom controls up one token tier so they match the top toolbar's prominence,
in `Views/BottomBar.swift`:

- Search field glyphs -> `sizeLg` (18pt), field text -> `sizeBase` (16pt), vertical
  padding -> `x3` (12pt) so the pill is taller.
- `BottomBarIconButton`: glyph -> `sizeXl` (20pt), frame -> `x10` (40pt).
- `BottomBarRecordButton`: mic -> `sizeLg` (18pt), frame -> `x10` (40pt).

The button-group and search pills stay sibling capsules; the larger frames make the
group pill grow to match the taller search pill. Colors, shapes, and accessibility
labels are unchanged.

## Acceptance

- The search field and the bottom action buttons visually match the top toolbar button
  size.
- Full suite green.
