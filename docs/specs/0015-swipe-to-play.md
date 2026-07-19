# 0015 - Swipe to play, folder queue, and a now-playing bar

## Problem

Playing a recording means opening the note and tapping Play. For an audio app you want to start a
recording - or a whole folder of them - with one gesture, and see what's playing without leaving the
list. There is no fast play gesture and no on-screen player.

## Outcome

- **Swipe a note right to play it.** A full leading swipe on a note with a recording starts playing it
  immediately through the shared playback controller (lock-screen / Control Center Now Playing light
  up as they already do). A text-only note offers no play swipe.
- **Swipe a folder right to play the folder.** A full leading swipe on a folder plays its recordings
  as a QUEUE, one at a time, auto-advancing to the next when one finishes - its recorded notes
  (anywhere in the folder's subtree), in the current sort order, skipping text-only notes.
- **A now-playing bar.** While something plays from the list, a compact bar sits above the Record
  button: the current title, play/pause, and stop; when a queue is running it also shows Next. Tapping
  the bar opens that note. It disappears when playback stops or the queue ends.
- Reinforces the CarPlay Audio identity (a real library with queue playback), and text-only notes are
  never in a queue.

## Scope

**In:** a leading swipe action on note rows (play) and folder rows (play queue); a queue capability on
`NotePlaybackController` (ordered notes, auto-advance on finish, next/stop); a `NowPlayingBar` view
bound to the controller; wiring in `FolderContentsView` (swipes) and the list host (the bar). Reuses
the existing single-note playback + system Now Playing (spec 0008).

**Out:** shuffle / repeat, a full-screen player, reordering a queue, per-paragraph seek, CarPlay-side
queue UI (the phone bar is the surface here), and playing a text-only note via TTS from a swipe
(text-only notes are simply skipped / not offered).

## Approach

- **Queue on the controller.** Add an internal ordered `queue: [Note]` + index to
  `NotePlaybackController`. `playQueue(_ notes:)` filters to notes with a recording, plays the first,
  and `handleFinish` (the natural end-of-track path) advances to the next until the queue is empty,
  then clears. `stop()` clears the queue. Expose enough published state for the bar: current title,
  isPlaying/isPaused, and `hasNext` / a `playNext()`. A single-note swipe uses the existing
  `play(note:)` (queue of one is fine too, but keep single-play simple). Keep the ONE-writer-of
  -`MPNowPlayingInfoCenter` invariant; the queue just changes which note is current.
- **Swipe actions.** In `FolderContentsView`, add a leading `swipeActions(edge: .leading,
  allowsFullSwipe: true)`: on a note row with `hasAudio`, a Play action calling
  `controller.play(note:)`; on a folder row, a Play action calling `controller.playQueue(...)` built
  from the driver's notes filtered to that folder's subtree (prefix match) with a recording, ordered
  by the current `NoteSortOrder`. A text-only note gets no leading Play action.
- **Now-playing bar.** A `NowPlayingBar` observing the shared controller, shown in the list host
  (`StreamListView`) in the bottom safe-area inset alongside the Record button (or just above it) when
  the controller has a current note. Play/pause, stop, and Next (when `hasNext`); tapping the title
  routes to that note. Themed with Canopy tokens.
- The controller is already the shared one from the composition root, so the detail view, the bar, and
  CarPlay all stay in sync.

## Acceptance

- [ ] Full leading swipe on a recorded note starts it playing; the bar appears with its title.
- [ ] A text-only note offers no leading Play action.
- [ ] Full leading swipe on a folder plays its recorded notes in order, auto-advancing; text-only
      notes are skipped; an empty/no-recordings folder does nothing.
- [ ] The bar shows play/pause + stop, and Next only while a queue has a next item; stop/queue-end
      hides it.
- [ ] Queue order follows the current sort; playing respects the shared controller (no second audio
      path; Now Playing stays single-writer).
- [ ] Full suite green; the queue logic (filter to recordings, order, advance, hasNext, clear) is
      unit-tested on the controller with the existing stubbed player.
