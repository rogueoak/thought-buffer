# Plan 0027 - Playback overhaul (bottom player, transport, Now Playing + Dynamic Island)

Source: `docs/specs/0027-playback-overhaul.md`. Supersedes spec 0015's simple now-playing bar and
extends spec 0008's Now Playing.

## Steps

1. **Pure core (`PlaybackProgress`).** A SwiftUI-free value/helper holding the clamping and formatting
   rules so they are unit-tested without audio or a controller:
   - `clamp(_:duration:)` -> clamp a target time to `[0, duration]` (skip past end -> duration, before 0
     -> 0). Reuses the same rule `SystemAudioThoughtPlayer.clampedSeekTime` already applies at the player,
     so the two cannot drift.
   - `fraction(elapsed:duration:)` -> progress fraction in `[0, 1]` (0 when duration <= 0).
   - time formatting delegates to the existing single source `Thought.durationLabel` (0:00, 0:09, 1:24,
     hour rollover); `remaining(elapsed:duration:)` -> a "-m:ss" countdown label.

2. **Extend `ThoughtPlaybackController`.**
   - Publish `elapsed` and `duration` (duration from the loaded thought's `recordingDuration`).
   - A progress TICKER (a `Task` sleeping ~0.25s) started on play/resume, stopped on pause/stop/finish,
     that reads `player.currentTime` into `elapsed` and refreshes Now Playing so the lock screen / Dynamic
     Island track live.
   - `seek(to:)` -> clamp via `PlaybackProgress.clamp`, seek the player, update `elapsed` + Now Playing.
   - `skip(by:)` already exists; route its clamp math through the same rule and update `elapsed`.
   - Wire `changePlaybackPositionCommand` through the remote seam (scrub from system UI) -> `seek(to:)`.

3. **Now Playing / remote seam (`NowPlayingCenter`).** Add a `scrub: (Double) -> Void` handler to
   `RemoteCommandRegistering.register`, wired to `MPRemoteCommandCenter.changePlaybackPositionCommand`
   (reads `MPChangePlaybackPositionCommandEvent.positionTime`). Spy captures + fires it in tests.

4. **Bottom player view.** Upgrade `NowPlayingBar` into a full `BottomPlayer`: title, play/pause,
   skip-back 15s, skip-forward 15s, a draggable progress `Slider` (elapsed vs duration) that seeks on
   change, elapsed + remaining labels, Next while a queue has one. Accessible labels on every control.
   Rendered in ONE place (`StreamBottomStack`) so compact + iPad lifted stack both get it.

5. **Remove in-note playback.** Drop the `playButton`, the `ThoughtPlaybackModel` `@StateObject`, and the
   `canPlay` gate from `ThoughtDetailView`. Playing a recorded thought (row / detail / queue) now surfaces
   the bottom player only. Delete `ThoughtPlaybackModel` + its tests if nothing else uses it; keep the
   detail view's other responsibilities (edit, find, resume, actions) intact. The detail view still needs
   a way to START playback from... (decision: the row is the play entry point per spec 0026's
   `ThoughtResultRow`; the detail view no longer starts playback, matching "the thought screen no longer
   hosts its own play controls"). Route a "play this thought" from the detail header via the shared
   controller so a recorded thought opened directly can still be played -> a single "Play" affordance that
   drives `controller.play(thought:)` and surfaces the bottom player, NOT an in-note transport.

6. **Tests.** `PlaybackProgressTests` (clamp, fraction, formatting, remaining). Extend
   `ThoughtPlaybackControllerTests`: elapsed publishes on play/seek/skip, seek clamps, the scrub remote
   command seeks, duration published. Keep the folder-queue tests green.

7. **Reflect.** Update `docs/overview/features.md`, `architecture.md`, `learnings.md`.

## Verification

Full suite green on iPhone 17, no new warnings. Device-verify: real audio playback, the live Now Playing /
Dynamic Island render, and the system remote commands (play/pause, +/-15s, scrub).
