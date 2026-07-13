# 0007 - Dual-capture recording and recording playback

## Problem

Dictation (spec 0002) keeps only the text. The raw voice is thrown away the instant a segment
finalizes, so "Mira read that back" (spec 0003) can only re-synthesize the words with text to
speech, never replay how they were actually said, and a saved note can never be heard back. The
product's promise is to capture a thought the way you spoke it. This milestone keeps the real
audio alongside the transcript and plays it back.

It also gives the app a genuine voice-recording and playback identity, the basis a later
milestone needs to ask Apple for a CarPlay Audio-category entitlement (out of scope here).

Who it is for: on-device testers who want to hear a note back in their own voice, and who want
control over whether raw audio is kept at all.

## Outcome

Observable behavior when done:

- While a dictation session runs, the same microphone feed that drives recognition is also
  written to a compressed `.m4a` file for that note, on device. Recognition is unchanged and
  nothing leaves the device.
- One continuous recording spans the whole session even though the recognizer restarts its task
  many times (duration limits, hiccups). The recording is not chopped at each restart.
- Each finalized paragraph knows its time range in the recording (start + duration), captured
  from the recognizer's segment timings. The timings persist with the note.
- "Mira read that back" plays the ACTUAL recording of the last paragraph (seeked to its range).
  A note can be played in full from its detail view (simple play / stop). When a note or
  paragraph has no audio, playback falls back to the existing text-to-speech `Speaker`.
- A Settings option controls retention: keep audio (default), transcript-only (never record), or
  auto-delete audio after N days. Transcript-only skips the file writer entirely.
- Deleting a note deletes its audio file. The audio file lives next to the note (`<id>.m4a` by
  `<id>.md`) and syncs through the same storage layer with the same coordination and protection.
- Notes without audio or timings load exactly as today (backward compatible).

## Scope

In:
- A tee in the capture service: input-tap buffers feed the recognizer AND an `AVAudioFile`
  writer, one continuous file across recognizer-task restarts.
- Finalized-segment events carry a time range derived from `SFTranscriptionSegment`
  timestamp/duration.
- `Note` gains an optional audio reference and per-paragraph timings, persisted (tolerant,
  backward compatible).
- `AudioNotePlayer` protocol (production `AVAudioPlayer`-backed, range/seek playback; stubbable).
  `readThatBack` routes through it with the text-to-speech fallback. Detail-view full-note play.
- Retention setting on `SettingsStoring`: keep / transcript-only / auto-delete after N days.
- Storage manages the sibling audio file: `NoteStoring` extends to save/delete/locate audio;
  `NoteStore` and `ICloudNoteStore` handle `<id>.m4a` with the same `NSFileCoordinator` and
  `FileProtection.completeUnlessOpen` guarantees. Auto-delete sweeps expired audio.
- README / privacy copy notes that recordings are stored (local by default, optionally iCloud)
  and can be turned off or auto-deleted.

Out (later milestones):
- The CarPlay Audio surface and its entitlement.
- A recordings list / waveform scrubber UI beyond simple play, and parameterized playback
  controls (rate, skip). Detail-view playback stays play / stop.

## Approach

- **Tee.** The single input tap already feeds the recognizer and the waveform. Add a third sink:
  an `AVAudioFile` opened once when capture starts, written from the tap on the audio thread. The
  writer is created by the service and lives for the whole session; recognizer-task restarts
  (`restartTaskIfCapturing`) only swap the recognition request, never the file, so the recording
  is continuous. Pause closes nothing about the file position mid-session is not required for this
  milestone: pause stops the engine, so the file simply has no more frames appended; resume keeps
  appending to the same file (the file is per session/note, opened at `start`, finalized at
  `stop`). The writer is an actor-free, off-main helper touched only from the audio thread plus
  the main-actor lifecycle calls, mirroring how the tap already isolates the request.
- **Timings.** `SFSpeechRecognitionResult.bestTranscription.segments` carry `timestamp` and
  `duration` (seconds from the start of the recognition request). Because the request restarts,
  segment timestamps are relative to each request, so the service tracks a running offset (audio
  seconds elapsed at each restart, counted from frames appended to the file) and maps a finalized
  segment's range to absolute file time. The finalized event carries `(start, duration)` in
  seconds. The view model records the range for each committed paragraph.
- **Persistence.** Store per-paragraph timings and the audio filename in the note. To keep the
  Markdown body clean and the parse tolerant, persist timings as frontmatter (`audio:` filename
  and `timings:` a compact JSON array of `[start,duration]` pairs, one per paragraph). Unknown to
  an old parser, ignored; absent for a text-only note, which loads exactly as today.
- **Player.** `AudioNotePlayer` protocol: `play(url:from:duration:)` (a nil duration plays to the
  end) and `stop`, with an `onFinish`. Production wraps `AVAudioPlayer`, sets the session to
  `.playback`, seeks to `from`, and stops at `from + duration` (a lightweight timer, since
  `AVAudioPlayer` has no native stop-at). Recorded playback of the actual voice is a SAVED-note
  feature (a finalized file) via `NotePlaybackModel` in the detail view. IN-SESSION `readThatBack`
  stays on the `Speaker`: the live `.m4a` is still open for writing (finalized only at `stop()`, not
  the `pause()` read-back uses), so there is no finalized file to play mid-session. Both reuse the
  existing pause-capture-during-playback handshake, and the seam documents that the recording URL is
  finalized only after `stop()` so a future headless consumer stays off the in-flight file.
- **Retention.** Add `audioRetention` to `SettingsStoring` (`keep` default / `transcriptOnly` /
  `autoDeleteDays(Int)`), persisted in `UserDefaults`. The view model reads it to decide whether
  to record; `transcriptOnly` never opens the writer. Auto-delete is a sweep at launch (and after
  load) that deletes audio siblings older than N days through the store.
- **Storage.** `NoteStoring` gains `audioURL(for:)`, `saveAudio(from:for:)`, and
  `deleteAudio(for:)` (delete-note also deletes audio). Both stores place `<id>.m4a` beside
  `<id>.md` with the same protection; `ICloudNoteStore` coordinates every audio operation.

## Acceptance

- [ ] `xcodegen generate`; build for `iPhone 17` simulator succeeds.
- [ ] App launches and runs; transcript-only mode works; no crash without a real mic.
- [ ] Unit tests, all green (existing + new):
  - [ ] tee writes a file when retention is keep, skips it when transcript-only (injected buffers)
  - [ ] paragraph <-> time mapping is correct across a simulated recognizer restart (pure
        `RecordingTiming` offset math)
  - [ ] `Note` (de)serialization round-trips with AND without audio / timings (backward compatible),
        including through the store
  - [ ] saved-note playback plays the correct range via a stubbed `AudioNotePlayer`; in-session
        read-back speaks via the `Speaker`
  - [ ] deleting a note deletes its audio; storage saves / deletes the sibling audio (coordinated)
- [ ] Detail view shows a Play affordance; screenshot at `design/screenshots/note-playback.png`.
- [ ] README / privacy copy updated.

Real mic capture and playback quality can only be confirmed on a physical device; the simulator
mic does not produce meaningful audio. The pipeline is proven structurally and by tests.
