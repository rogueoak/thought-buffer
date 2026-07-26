# 0012 - Animated launch cover

## Problem

The app opens straight onto the Thoughts list (after a brief themed-background flash while storage
resolves). There is no branded launch moment - nothing that says "this is a voice app" or gives the
open a bit of delight. The developer wants a short, cool cover screen on startup: the app icon
animated as if a voice were speaking, held for a couple of seconds, then dissolving into the app.

Note: iOS's system launch screen is a STATIC image shown before app code runs and cannot be animated,
so this is an in-app cover the SwiftUI root presents first and then dismisses.

## Outcome

- On a normal cold launch the app shows a full-screen cover on the River Mist background: the app
  icon centered, with a row of waveform / equalizer bars beneath it that rise and fall as if reacting
  to a voice.
- The cover holds for a few seconds (~2.5s), then cross-fades into the Thoughts list.
- It covers the brief storage-resolution flash, so the open feels like one smooth moment rather than
  background -> pop -> list.
- Tapping the cover skips it immediately (no forced wait).
- Respects Reduce Motion: with it on, the bars hold static (or a single gentle pulse) instead of
  animating, and the cover still auto-dismisses.
- Screenshot/tooling launches (`-uiScreen ...`) do NOT show the cover, so automated captures are
  unaffected.

## Scope

**In:** an in-app `LaunchCoverView` (icon + animated waveform bars, themed), shown once per cold
launch before the Thoughts list, auto-dismissing after a short hold with a cross-fade, tap-to-skip,
Reduce-Motion fallback.

**Out:** changing the system launch screen, a first-run-only variant, sound on launch, and any
per-launch configurability. No storage, capture, or navigation change.

## Approach

- **`LaunchCoverView`** - a self-contained SwiftUI view: the `AppIcon` image (rounded) centered over
  `CanopyColor.bg`, with an animated bar row below it. The bars are driven by a `TimelineView`
  (`.animation`) or a repeating `withAnimation` timer, each bar's height a phase-shifted sine so the
  row looks like speech, using `CanopyColor.primary`. Pure visual; no mic, no audio, no dependencies.
  A `reduceMotion` environment check swaps the animation for a static row.
- **Gate in `ThoughtBufferApp`.** Add a `@State showLaunchCover = true` shown as an overlay/`ZStack`
  on top of `content` for normal launches only (skipped when `-uiScreen` is present). A `.task`
  waits `max(minimum hold, until dependencies resolve)` then sets it false inside a
  `withAnimation(.easeOut)` so it cross-fades out; a tap on the cover sets it false early. The cover
  sits above the pre-resolution themed background so there is no visible pop.
- Keep the hold duration and bar count as named constants so they are easy to tune.

## Acceptance

- [ ] A normal launch shows the icon with animated waveform bars on the themed background, then
      cross-fades to the Thoughts list after ~2.5s.
- [ ] Tapping the cover dismisses it immediately.
- [ ] With Reduce Motion on, the bars do not animate and the cover still auto-dismisses.
- [ ] A `-uiScreen` launch shows no cover (screenshot tooling unaffected).
- [ ] The cover covers the storage-resolution period (no themed-background flash before it).
- [ ] Build green; the bar-height math (the pure part) is unit-tested.
