# 0019 - Launch cover: thinner bars, borderless logo fading into background

- **Source:** Device feedback from Matthew (2026-07-19).
- **Observation:** "On the loading screen, the wave looks good, make it thinner bars, more
  like the logo. And remove the logo border and make it fade into the background."

## Symptom

Two visual issues on the animated launch cover (spec 0012):

1. The equalizer bars were chunky (8pt wide with an 8pt gap), so the row read as blocks rather
   than the finer waveform seen in the logo art.
2. The logo sat on top of the background as a crisp rounded tile with a shadow, so it had a hard
   boundary instead of melting into the River Mist backdrop.

## Fix

Visual-only changes in `ios/ThoughtStream/Views/LaunchCoverView.swift`. The animation math and
direction, bar count, heights, and the "Thought Stream" title (feedback 0018) are unchanged.

1. **Thinner bars.** Narrowed the bar width from `CanopySpacing.x2` (8pt) to `CanopySpacing.x1`
   (4pt) and tightened the gap from `x2` (8pt) to a named `barSpacing` of `x1_5` (6pt), so the
   row reads as a finer, logo-like waveform. Both are named constants so they stay tunable.
2. **Removed the logo border.** Dropped the `clipShape(RoundedRectangle(...))` and the `shadow`
   around the icon, so there is no outline or hard tile edge.
3. **Logo fades into the background.** Applied a soft `RadialGradient` mask (`logoFadeMask`):
   solid white through the center out to 60% of the radius, fading to clear by the edge, so the
   icon melts into the launch backdrop rather than sitting on it with a crisp boundary. Uses the
   mask alpha only (no hardcoded brand colors; the visible art stays the `LaunchIcon`).

## Acceptance

- The launch cover shows a finer, thinner waveform (device-verifiable).
- The logo has no border/outline/shadow and its edges fade into the River Mist background
  (device-verifiable).
- The bar count, reversed wave direction, heights, and title are unchanged.
- No pure helper math changed, so the existing `LaunchCoverViewTests` still pin the animation
  contract. Full test suite green (591 tests, 0 failures).

## Learning

None that generalizes past this change - a launch-cover visual tweak belongs in the feature's
own story (`overview/features.md`), not the shared learnings.
