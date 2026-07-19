# Feedback 0027 - Playback fixes: anchor the in-note player, resume progress after a scrub

Two device-report playback bugs against the spec 0027 bottom player (items 9 and 10 of a
list). Both are fixed here; the pure bits are unit-tested.

## Item 9 - The in-note play control must anchor to the bottom player, and its transport must work on the thought page

### Symptom

> Within a thought, the play recording button needs to be anchored with the search bar. The
> audio controls should then work on that page, just like how it works on other pages.

On the phone (compact `NavigationStack`) the persistent bottom player (`BottomPlayer`) shows
above the search bar on the list / folder screens - it is rendered inside `StreamBottomStack`,
which each of those screens hosts in its own `.safeAreaInset(edge: .bottom)`. But
`ThoughtDetailView` hosts a DIFFERENT bottom inset - only its own find / resume `BottomBar` -
so pushing into a thought made the shared player vanish, and the transport (play / pause,
scrubber, +/-15s) was unreachable while reading the thought.

The iPad split view was already correct: there the bottom stack is LIFTED above all three
columns (`StreamListView.liftedBottomStack`), so the detail column always shows the player.
Only the compact detail page was missing it.

### Root cause

The bottom PLAYER lives in `StreamBottomStack`, rendered only by the list / folder screens.
`ThoughtDetailView`'s `.safeAreaInset(edge: .bottom)` rendered just its own `BottomBar`, never
the shared player, so the one-and-only bottom player was not surfaced on the pushed detail
screen in the compact container.

### Fix

`ThoughtDetailView` already receives the ONE shared `ThoughtPlaybackController`. Its bottom
inset now renders the SAME `BottomPlayer(controller:)` above its own `BottomBar`, in a `VStack`
matching the order the shared `StreamBottomStack` uses (player above the bar). No second player,
no second audio path - the detail page observes the same controller the list screens do, so the
transport works there identically (the controller, the ticker, seek, and Now Playing are all
shared). The player renders itself only while a recording is loaded (it collapses to nothing
otherwise), so a thought with nothing playing shows just the search / resume bar as before.

Whether the detail hosts the player is a SINGLE container decision -
`StreamContainer.detailHostsBottomPlayer` (the same seam `folderScreenShowsOwnBottomBar` uses):
true on the compact stack (the push swaps the inset, so the detail re-hosts it), false in the
split view (the player is lifted above all columns, so the detail column must not host it or it
double-renders). `StreamListView.detailView` derives the flag from the container rather than
passing a per-call-site literal, so a future lifting container cannot silently double-render.

Placement decision: the thought detail page HAS a bottom bar by design (its find field + resume
icon), so the player anchors directly above that bar in the same bottom safe-area inset - the
exact position the list screens use - and the whole inset stays consistent across screens.
Tapping the bottom player's title opens the tapped thought, wired here to the detail's own
`onOpenThought` (a no-op re-open of the current thought is harmless; a queue-advanced other
thought pushes as usual).

## Item 10 - Progress stalls after scrubbing (BUG)

### Symptom

> After scrubbing to a new point on the audio track playback, the progress stops moving.

After dragging the scrubber to seek, the progress bar froze at the drop point even though the
recording kept playing.

### Root cause

`BottomPlayer` held the in-drag thumb value in `@State scrubbing: Double?` and displayed
`scrubbing ?? controller.elapsed`. It cleared `scrubbing` back to nil ONLY inside
`Slider.onEditingChanged(editing: false)`. But a `Slider`'s value-binding `set` and its
`onEditingChanged(false)` callback are not ordered guarantees: the slider can fire the binding's
`set` (`scrubbing = $0`) with the final touch-up value AFTER `onEditingChanged(false)` already
ran `scrubbing = nil`. That re-populates `scrubbing`, so `displayed` reads the frozen scrub value
forever and the live `elapsed` (still advancing under the ticker) is permanently suppressed - the
bar stalls. The seek itself worked; the display just stopped tracking playback.

`NowPlayingBar.swift` (the `displayed = scrubbing ?? controller.elapsed` in `progressRow`) is
the stall; the fragile clear lived in `onEditingChanged`.

### Fix

Decouple "show the scrub value" from callback ordering with an explicit drag flag. `BottomPlayer`
now tracks `@State isScrubbing: Bool` set true on `onEditingChanged(true)` and false on
`onEditingChanged(false)`, and the displayed value is the pure
`PlaybackProgress.scrubDisplay(isScrubbing:scrubValue:elapsed:)`: while scrubbing it shows the
held scrub value, otherwise it ALWAYS shows the controller's live `elapsed` - so a stray
post-release `set` write to `scrubbing` cannot permanently suppress progress, because the display
ignores `scrubbing` the moment the drag ends. On release the final position is committed via
`controller.seek(to:)` (which clamps, updates published `elapsed`, and refreshes Now Playing),
the ticker (never stopped during the drag - playback continued) picks the new position up, and
the bar resumes advancing from it.

### Tests

- `PlaybackProgressTests.testScrubDisplayShowsScrubValueWhileScrubbing` /
  `...AtDragBeginShowsTheSeededElapsed` / `...ShowsElapsedWhenNotScrubbing` /
  `...IgnoresStaleScrubValueAfterDragEnds`: the pure display rule is the HONEST regression guard
  for the stall - it proves the editing state cannot permanently suppress live progress (a
  leftover scrub value with `isScrubbing == false` still yields `elapsed`), which fails against
  the old `scrubbing ?? elapsed` display. (The stall lived in the view layer, so this pure rule -
  not a controller test - is what guards it.)
- `ThoughtPlaybackControllerTests.testSeekDoesNotStopTheTickerSoElapsedKeepsAdvancing`:
  model-level, no real audio - pins a CONTROLLER-side property behind the fix (a seek must not
  stop the live-progress ticker), so a future change that DID pause the ticker on seek is caught.
  It holds on `main` already (this property was never broken), so it is a forward guard, not the
  stall's regression test - the pure `scrubDisplay` tests are that.
- `ThoughtPlaybackControllerTests.testSeekWhilePausedThenResumeAdvancesFromSoughtPosition`: the
  paused-scrub equivalence class - a paused seek sets `elapsed` but does not start the ticker; a
  following `resume()` advances `elapsed` from the sought position.
- `AdaptiveLayoutTests.testCompactDetailHostsTheBottomPlayer` /
  `...testSplitDetailDoesNotHostTheBottomPlayer`: lock the container decision so a future lifting
  layout cannot silently double-render the player.
- Existing `testSeekClampsToDuration` / `testSeekUpdatesElapsedAndSeeksPlayer` continue to prove
  the seek clamps to `[0, duration]` and updates `elapsed` immediately.

## Learning

A SwiftUI `Slider`'s binding `set` and its `onEditingChanged` are not ordered relative to each
other, so clearing a "user is dragging" hold ONLY inside `onEditingChanged(false)` is fragile: a
late `set` can re-arm the hold and permanently mask the live value. Gate "show the dragged value"
on an explicit `isDragging` flag and fall back to the live source the instant the flag drops -
never on the assumption that `onEditingChanged` fires last. And keep the display-selection rule a
pure function so the "editing state cannot suppress live progress forever" invariant has a CI gate
instead of being device-only. Separately: when a persistent affordance (the bottom player) must
appear on EVERY screen, host it once per container layout - the compact stack pushes a detail view
with its OWN bottom inset, so the shared inset content has to be repeated there, not assumed to
carry over from the pushing screen.
