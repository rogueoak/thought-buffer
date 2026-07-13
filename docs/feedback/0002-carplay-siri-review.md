# 0002 - CarPlay and Siri review findings

Feedback from the persona review of PR #5 (spec 0005, CarPlay and Siri hands-free start).

## Symptom

One blocker and a few minors surfaced on the first cut:

- **Cold-launch start silently dropped (engineer blocker, architect major).** The shippable path -
  "Hey Siri, start a stream" from a not-running app - was lost. `openAppWhenRun` launches the app
  and runs the intent's `perform()`, but `AppDependencies.shared` (and thus the live session route)
  is only set at the END of `resolve()`, which `await`s an off-main container lookup. So on a cold
  launch `perform()` read `nil` from `sessionStarter`, `startNewSession()` was a no-op, and the app
  foregrounded to the Stream list with no dictation. Same hole for `NewNoteIntent` and CarPlay.
- **The flag -> present routing was untested (tester major).** The tests proved `startRequested`
  flips, but nothing asserted that flipping it opens `DictationView`, that a backgrounded start
  opens on appear, or that a second start after a save re-opens. The routing lived inline in the
  view's `onChange`, untestable.
- **Re-request while presented was lost (engineer minor).** With presentation driven by `onChange`
  edges, a start requested while `DictationView` was already up saw no transition and evaporated on
  `consume()` at dismiss.
- **Shortcut app-name assertion dropped (tester minor).** Because `AppShortcut.phrases` is not
  public and phrases interpolate the app name, the test fell back to a brittle Mirror phrase-count
  and stopped asserting the phrasing / app-name contract at all.
- **Spec/code drift on the scene manifest (architect minor).** The spec said the manifest kept
  `UIApplicationSupportsMultipleScenes` semantics intact; the code flipped it false -> true (correct
  and necessary for CarPlay, safe on an iPhone-only app).

## Root cause

The pending-route buffer was designed for "requested while not on screen" but the route object was
reachable only after the UI resolved it, so the buffer never engaged on the one path that needed it
most - a cold hands-free launch, where the intent runs before any UI exists. Presentation logic and
the phrasing contract were left inside the view / interpolated into an opaque type, so both went
untested.

## Fix

- `AppDependencies.sessionStarter` is now non-optional: before the root resolves it returns a
  `ColdStartSessionStarter` that records the request on a process-wide
  `PendingSessionRoute.pendingColdStart` latch; the first route created adopts and clears it, so a
  cold-launch start always lands. Covered by tests.
- Presentation is a pure `SessionRouting.shouldPresent(startRequested:)` the root binds to (get =
  should-present, set(false) = consume), unit-tested for open / consume / re-open, so a re-request
  after a session ends re-opens and nothing is lost on an edge.
- The shortcut phrase leads are mirrored as testable `static let` arrays, and the test asserts the
  wording and that each rendered phrase ends with the app name.
- Spec text reconciled with the `UIApplicationSupportsMultipleScenes: true` change.

## Learning

When an OS-instantiated entry point (an App Intent, a scene delegate) reaches app state through a
process-wide accessor, that accessor must be valid at the EARLIEST moment the entry point can fire -
which for `openAppWhenRun` intents is a cold launch, BEFORE async startup resolution completes. A
"buffer for requests made off-screen" only works if the buffer exists independent of the UI/startup
that populates it; otherwise the very first request (the one that launched the app) is the one it
drops. Give such a seam a resolution-independent latch, and make the request path never return a
nil/no-op starter. This generalizes past this feature to any future OS-triggered entry point.
