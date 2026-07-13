# 0008 - CarPlay Audio surface, shared playback, and system Now Playing

## Problem

Spec 0007 gave Thought Stream a real voice-recording and playback identity: each note keeps a
compressed `.m4a` of the voice that produced it, with per-paragraph timings, and the detail view
plays it back. Spec 0005 scaffolded a dormant CarPlay scene with one "Start a thought stream" row.
Neither yet makes the app an Audio app: there is no way to browse and play your recordings in the
car, and playing a note on the phone shows nothing on the lock screen or Control Center.

This milestone turns those pieces into a genuine Audio-app surface - browse your voice notes and
play them in CarPlay Now Playing and on the lock screen - which is the concrete basis for asking
Apple for the CarPlay **Audio** entitlement (`com.apple.developer.carplay-audio`).

Who it is for: on-device drivers who want to hear a note back hands-free in the car, and any user
who plays a note on the phone and expects lock-screen / Control Center transport like any audio app.

## Outcome

Observable behavior when done:

- **CarPlay recordings browser.** The CarPlay root is a `CPListTemplate` listing notes that HAVE a
  recording, newest first, each row showing title, relative date, and recording duration. A top
  "Start a thought stream" row still triggers the shared `SessionStarter` (hands-free capture).
  Tapping a note plays its `.m4a` and pushes the CarPlay Now Playing template with working play /
  pause (and skip-forward / skip-back over the note). When the note list changes (a session saved, a
  synced-in note), the list refreshes live.
- **System Now Playing + remote commands (phone AND CarPlay).** Playing a note populates
  `MPNowPlayingInfoCenter` (title, total duration, elapsed) and wires `MPRemoteCommandCenter`
  (play, pause, stop, skip) to the playback controller, and the app declares the `audio`
  `UIBackgroundModes`, so a note played on the phone shows Now Playing on the lock screen and in
  Control Center and keeps playing in the background. This is a real Audio-app trait and needs no
  entitlement.
- **One shared playback path.** A single headless `NotePlaybackController` owns the player, the
  lazy off-main URL resolution, and the Now Playing / remote-command wiring. Both the phone detail
  view and the CarPlay scene drive it, so there is exactly one audio path feeding
  `MPNowPlayingInfoCenter`. `AVAudioSession` is set to `.playback` for playback and coexists with the
  record session used during dictation.
- **Green unsigned, no entitlement.** The CarPlay scene stays dormant without the CarPlay Audio
  entitlement, exactly like the 0005 scaffold: the unsigned Simulator build and the App Store build
  stay green with `DEVELOPMENT_TEAM` empty and no CarPlay entitlement declared. A request-draft doc
  states the honest justification and the exact steps to enable it once Apple grants it.

## Scope

In:
- A headless `NotePlaybackController` (`@MainActor`) extracted from / extending the 0007 playback
  pieces: play / pause / resume / stop / skip of a saved note's recording via `AudioNotePlayer`,
  lazy off-main URL resolution via `AudioURLResolving`, and `MPNowPlayingInfoCenter` +
  `MPRemoteCommandCenter` wiring. `AudioNotePlayer` gains `pause()` / `resume()` and an elapsed-time
  read so the controller can publish progress.
- `NotePlaybackModel` becomes a thin projection over the controller so the detail view keeps its
  play / stop button and the existing 0007 tests stay meaningful (one audio path, not two).
- A headless `RecordingsListModel`: projects `NoteStoreDriver.notes` to only notes with audio,
  newest first, with a formatted duration per note (from `timings` - the recording length is the max
  of `start + duration`). Refreshes when the driver's list changes.
- The CarPlay scene upgraded: a root `CPListTemplate` (the Start row + a recordings section from the
  `RecordingsListModel`), tap -> drive the shared controller and present `CPNowPlayingTemplate` with
  play/pause + skip buttons wired to the controller. Live refresh on driver change.
- `audio` in `UIBackgroundModes` (Info.plist) so background playback and lock-screen Now Playing
  work. NO CarPlay entitlement on the shipping target.
- Unit tests: the recordings-list model (audio-only, sorted, duration formatting), the playback
  controller (play/pause/stop via a stubbed player, MPNowPlayingInfo populated, remote-command
  handlers call the controller, session `.playback`), driver-change -> list refresh, and the Start
  row calling the shared `SessionStarter`.
- Docs: this spec, `docs/carplay-audio-entitlement-request.md`, README / privacy note, and the
  `docs/overview/` living docs.

Out (later milestones):
- A waveform scrubber / per-paragraph seek UI, and CarPlay in-drive live-capture UI beyond the Start
  action.
- Siri "play my last note" intents (optional; only if cheap).
- Adding the CarPlay Audio entitlement to the shipping target (blocked on Apple approval) - the
  request doc prepares it.

## Approach

- **Shared controller.** `NotePlaybackController` (`@MainActor ObservableObject`) is the one audio
  path. It holds an `AudioNotePlayer`, an `AudioURLResolving`, and `nowPlaying`/`isPlaying` state.
  `play(note:)` resolves the URL off-main (as 0007's model does), starts full-note playback, sets
  `MPNowPlayingInfoCenter` (title, `MPMediaItemPropertyPlaybackDuration` from the note's timings,
  elapsed 0), and enables remote commands. `pause()` / `resume()` / `stop()` / `skip(by:)` drive the
  player and update Now Playing elapsed + rate. `AudioNotePlayer` gains `pause()`, `resume()`, and a
  `currentTime` read; `SystemAudioNotePlayer` implements them over `AVAudioPlayer` (which pauses and
  resumes natively and reports `currentTime`). The `MPRemoteCommandCenter` handlers (togglePlayPause,
  play, pause, stop, skipForward/Backward) call straight into the controller, so the lock screen and
  a CarPlay head unit both drive the same code. `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`
  are injected behind small protocols (`NowPlayingInfoWriting`, `RemoteCommandRegistering`) so the
  wiring is unit-testable with a spy and no real media center.
- **NotePlaybackModel projection.** The detail view's model keeps its `toggle()` / `isPlaying` /
  `canPlay` API but delegates to a `NotePlaybackController`, so there is one path. The 0007 tests
  (stubbed player + resolver, lazy resolution) still hold because the controller uses the same
  seams.
- **Recordings list.** `RecordingsListModel` (`@MainActor`) wraps a `NoteStoreDriver`, exposes
  `entries` = notes with `hasAudio`, newest first, each with a `durationLabel` (mm:ss). Recording
  length per note is `max over timings of (start + duration)` (the tail of the last paragraph);
  formatting is a pure function so it is unit-tested directly. It sets `onChange` so a driver reload
  republishes, mirroring `StreamFeed`.
- **CarPlay scene.** `CarPlaySceneDelegate` builds a `RecordingsListModel` from
  `AppDependencies.shared` on connect, starts it, and renders a `CPListTemplate` with two sections:
  the Start row (calls `AppDependencies.sessionStarter`) and one row per recording (title / date +
  duration detail). A row tap drives the shared `NotePlaybackController.play(note:)` and pushes a
  `CPNowPlayingTemplate` with play/pause and skip buttons wired to the controller. The list refreshes
  on the model's `onChange`. The scene is still gated: no CarPlay entitlement is declared, so the
  system never creates it - the phone scene and the unsigned build are unaffected.
- **System Now Playing.** Adding `audio` to `UIBackgroundModes` is the one Info.plist change needed
  for lock-screen Now Playing + background playback; it needs no entitlement and helps the phone app
  directly. `AVAudioSession` `.playback` is already set by `SystemAudioNotePlayer`; the controller
  keeps that and the record session coexists (dictation deactivates playback before recording, as
  0007 established).
- **Trade-offs.**
  - The controller centralizes Now Playing so there is exactly one writer of
    `MPNowPlayingInfoCenter`; the detail model no longer talks to the player directly. This is the
    "one audio path" the milestone requires, at the cost of a small projection layer.
  - CarPlay ships dormant (like 0005): the code is ready the day Apple grants the Audio entitlement,
    costs nothing at runtime while gated, and the default build stays green. The entitlement-request
    doc records the honest justification and exact enable steps.
  - Skip is a whole-note relative seek (`+/- N seconds` on `currentTime`), not per-paragraph - the
    paragraph scrubber is a later milestone. `MPNowPlayingInfoCenter` elapsed is updated on each
    transport action rather than on a display link (coarse but correct and cheap).

## Acceptance

- [ ] `cd ios && xcodegen generate`; build for `platform=iOS Simulator,name=iPhone 17` prints
      `** BUILD SUCCEEDED **` unsigned, no team, no CarPlay entitlement.
- [ ] The app still launches to the Stream list; the detail view's Play / Stop still works.
- [ ] Playing a note populates `MPNowPlayingInfoCenter` (title, duration, elapsed) and enables the
      remote commands; proven with a spy in a unit test. On a device this shows on the lock screen /
      Control Center (screenshot to `design/screenshots/now-playing.png` if capturable; otherwise
      note it needs a device).
- [ ] The recordings-list model lists only notes with audio, newest first, with correct duration
      formatting; asserted in a test.
- [ ] The playback controller plays / pauses / resumes / stops / skips via a stubbed player, updates
      Now Playing, and its remote-command handlers call the controller; asserted in tests.
- [ ] A driver-list change refreshes the recordings list; asserted in a test.
- [ ] The CarPlay Start row calls the shared `SessionStarter`; asserted in a test.
- [ ] `xcodebuild test` passes: the 186 existing tests plus the new ones.
- [ ] `docs/carplay-audio-entitlement-request.md`, README, and `docs/overview/` document the Audio
      surface, the entitlement gating, and what needs Apple approval / a CarPlay simulator / a device.

CarPlay itself needs the CarPlay Audio entitlement plus a CarPlay head unit / the CarPlay simulator,
so it is proven structurally and by tests. Real mic capture and playback quality still need a
physical device (the Simulator mic produces no useful audio).
