# 0004 - CarPlay Audio surface review feedback

Findings from the persona review of PR #8 (spec 0008), and what changed.

## Symptom

- **(engineer, major) Stale Now Playing on a guarded play.** `NotePlaybackController.play(note:)`
  ran `stopPlayerOnly()` (which stopped the player but deliberately kept `currentNote` / Now Playing
  / remote commands, to re-wire them for the new note) BEFORE the `guard note.hasAudio` bail. So
  playing a no-audio note while another was playing stopped the current recording yet left the OLD
  note in `MPNowPlayingInfoCenter` with live remote-command handlers wired to a now-stopped
  controller. The failed-resolve branch in `startPlayback` had the same gap: a missing / swept file
  cleared `currentNote` but not the Now Playing item or the remote wiring.
- **(tester, major x2) Untested teardown behaviors.** The natural end-of-track finish (`handleFinish`
  clearing Now Playing / remote, and skipping that under `suppressFinish`) and the projection
  contract (`NotePlaybackModel.isPlaying` mirrors the shared controller only while ITS note is
  loaded) were not directly tested, so a regression could stay green.
- **(security, minor) Note content on the locked screen.** Publishing `note.title` (derived from the
  note's first line) to `MPNowPlayingInfoCenter` surfaces private note content on the lock screen /
  Control Center while the device is locked, undisclosed in the privacy copy.
- **(architect / engineer, minor) Single-writer by convention, not structure.** One
  `NotePlaybackController` TYPE but N instances (one per detail view, one in CarPlay) all write the
  `MPNowPlayingInfoCenter` singleton; `onTransportChange` is a single closure slot presented as
  "fan-out". Works only because one surface plays at a time.

## Root cause

- The stop/switch helper conflated two intents ("stop the player but keep the wiring to re-use" vs.
  "fully clear everything"), and the `hasAudio` guard was placed after the teardown, so a bail left a
  half-torn-down state. A guard that can abort an operation must run before that operation mutates any
  shared state.
- The proactively-added tests covered the happy path and the optimistic-state cases but not the
  teardown edges, because the teardown is the LEAST visible behavior (nothing on screen) and so the
  easiest to forget to assert.
- Now Playing was wired for the standard audio-app UX (show the track title) without weighing it
  against this app's stronger-than-usual privacy posture.

## Fix

- Hoisted `guard note.hasAudio` to the top of `play(note:)` (before any teardown), and replaced the
  ambiguous `stopPlayerOnly()` with a single `clearPlayback()` that stops the player AND clears
  `currentNote` / Now Playing / remote. Both the switch path and the failed-resolve branch now call
  it, so no stale metadata or wiring can survive a stop, a switch, or a failed play.
- Added tests: natural-finish teardown, failed-play teardown, a no-audio play NOT disrupting the
  current playback, skip-while-idle no-op, and the `NotePlaybackModel` projection reading not-playing
  once the controller loads another note. 211 tests pass.
- Documented the lock-screen-title tradeoff in the README privacy copy (it is the user's own content,
  never sent anywhere, and iOS's own "Show on Lock Screen" control hides it).
- Documented `onTransportChange` as SINGLE-observer by design (each surface owns its own controller
  instance) rather than pretending fan-out; a genuinely shared controller would need a multicast.

## Learning

- **A guard that can abort an operation belongs before the operation touches shared state**, not
  after a partial teardown - otherwise the abort path strands half-cleared state. This generalizes
  past playback to any "validate, then mutate" sequence.
- **Invisible teardown is the coverage a happy-path test misses.** When an action clears system
  state (Now Playing, registered handlers, singletons), assert the CLEARED state explicitly with a
  spy - a test that only checks "it played" never catches "it failed to un-wire". Feeds
  `overview/learnings.md`.
- **On a privacy-forward app, weigh every new system-surfaced value against the privacy posture.**
  Standard audio-app UX (a track title on the lock screen) can leak private content; either keep it
  generic or disclose it.
