# Feedback 0023 - Group the bottom-bar new-thought + record buttons

## Source

Device feedback from Matthew (2026-07-19) on the persistent bottom bar:

> Add a button group behind the new note and new recording in the bottom of the screen. Similar to the
> new folder and sort in the top left.

## Change

- **Symptom.** After feedback 0020 the new-thought and record icons sit BARE beside the search field, so
  the pair does not read as one grouped action set - unlike the top-left toolbar, where the new-folder and
  sort items share one background (iOS 26 groups adjacent toolbar items behind a single glass capsule).
- **Fix.** A small reusable `BottomBarButtonGroup` container wraps the new-thought + record pair in ONE
  shared background so the two read as a single grouped unit beside the search pill. The container carries
  the SAME Canopy surface + border + capsule + shadow treatment the search field uses (feedback 0020), so
  the group and the search field sit as sibling pills on the bar. Each wrapped button keeps its own tap
  target, accessibility label, and affordance - the record button keeps its filled-circle prominence
  INSIDE the group.
- **Scope.** The group wraps only the two-item list/folder pair (in the one shared `StreamBottomStack`, so
  the compact folder screen and the iPad lifted bar both get it from one place). The thought-detail
  screen's lone resume button is left bare - a one-item "group" would look like an empty container.
- **Match.** The top-left group is system-provided (two adjacent `.topBarLeading` toolbar items that iOS 26
  renders behind one shared background); SwiftUI does not expose that toolbar-group background for an
  arbitrary bottom-bar HStack, so the bottom group re-uses the search pill's explicit Canopy surface +
  border + capsule + shadow to read as the same "grouped behind one background" treatment. Canopy tokens
  only; no hardcoded colors.

## Acceptance

- The new-thought + record icons on the list and folder screens read as one grouped unit behind a shared
  rounded (capsule) background, visually distinct from the search field pill beside it.
- The group's background matches the search pill's surface + border treatment.
- The record button keeps its prominent filled-circle affordance inside the group.
- Each button keeps its tap target and accessibility label ("New thought", "Record").
- The thought-detail resume button stays a single bare button (no empty-looking group).
- The search field is unchanged (its own pill).
- Full test suite green (iPhone 17), build warning-free.
