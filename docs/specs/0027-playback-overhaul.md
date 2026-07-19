# Spec 0027 - Playback overhaul (bottom player, transport, Now Playing + Dynamic Island)

## Motivation

Device feedback from Matthew (2026-07-19):

> The recording playback needs proper play controls. It should show up in Now
> Playing as well and the Dynamic Island. It should be moved so that it isn't inside
> the note, it is at the bottom, just above the search bar. There should be a
> pause/play option, a progress bar and a skip backwards or forwards 15s.

This upgrades the now-playing bar (spec 0015) and the Now Playing integration (spec
0008) into a full transport, and moves playback out of the thought detail into a
persistent app-level bottom player.

## Depends on

Sequenced after spec 0026 (both restructure the bottom stack / list area).

## Scope

### 1. Persistent bottom player (not inside the thought)

- Playback UI lives in the bottom stack, positioned ABOVE the search bar (the same
  bottom safe-area inset that hosts the now-playing bar + bottom bar today). Order,
  top to bottom: transient undo chip -> PLAYER (when a thought is playing) -> search
  bottom bar.
- REMOVE the in-note playback UI from `ThoughtDetailView`: playing a recorded
  thought (from its row, the detail, or a folder queue) surfaces the bottom player;
  the thought screen no longer hosts its own play controls.
- The player shows the playing thought's title and transport; tapping it may open
  the thought (optional), but controls live in the bar.

### 2. Transport controls

- **Play / pause** toggle.
- **Progress / scrubber bar**: shows elapsed vs duration and lets the user drag to
  SEEK to a position. Live-updates as playback advances.
- **Skip back 15s / skip forward 15s** buttons (clamped to [0, duration]).
- Keep the existing queue behavior (spec 0015: play a folder one thought at a time)
  working - Next/advance still applies; the new transport is additive.

### 3. Now Playing + Dynamic Island

- Populate `MPNowPlayingInfoCenter` with title, duration, elapsed time, and playback
  rate, updated as playback advances and on seek, so the lock screen / Control
  Center / Dynamic Island show the thought with a live progress bar.
- Wire `MPRemoteCommandCenter`: play, pause, toggle, and `skipForwardCommand` /
  `skipBackwardCommand` with `preferredIntervals = [15]`, plus
  `changePlaybackPositionCommand` for scrubbing from the system UI. The audio
  session category must support background playback + remote control (as the audio
  app it already is).
- Dynamic Island: it appears automatically for an active Now Playing audio session;
  ensure the info center + remote commands are populated so its expanded controls
  (play/pause, ±15s) work. No custom ActivityKit widget required unless trivial.

## Design / factoring

- Extend the shared `ThoughtPlaybackController` with `seek(to:)`, `skip(by:)`
  (+/-15), published `elapsed`/`duration`/`isPlaying`, and the Now Playing / remote
  command wiring (via the existing `NowPlayingCenter` seam). Keep the pure bits
  (clamping a seek/skip to [0, duration], formatting elapsed/remaining) unit-tested.
- One player component reused wherever the bottom stack renders (compact + iPad
  lifted stack), consistent with `StreamBottomStack`.
- Canopy tokens; accessible labels on every transport control.

## Non-goals

- No playback speed control, no waveform scrubber (a simple progress bar is enough).
- No ActivityKit Live Activity beyond the system Now Playing / Dynamic Island.

## Acceptance

- Playing a recorded thought shows the player at the bottom (above the search bar),
  NOT inside the note; the thought screen has no in-note play controls.
- Play/pause, drag-to-seek, and skip +/-15s all work and clamp correctly; the
  progress bar tracks playback live.
- The lock screen / Control Center / Dynamic Island show the thought with a live
  progress bar and working play/pause + skip +/-15s (via MPRemoteCommandCenter).
- Folder-queue advance still works with the new transport.
- Pure seek/skip clamping + time formatting are unit-tested; full suite green.
