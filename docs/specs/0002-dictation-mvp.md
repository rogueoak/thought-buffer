# 0002 - On-device dictation MVP

## Problem

The themed shell (spec 0001) ships a mock dictation screen: a timer reveals a canned string,
the waveform is decorative, and nothing is saved. To be a real notes app, Thought Stream needs
to turn speech into text on the device and keep it. This milestone makes dictation real: you
tap Record, talk, and your words stream into a note that saves as a Markdown file and shows up
in the Stream list, all on device with no network.

Who it is for: the first on-device testers, who need to prove capture-to-save works before the
voice-editing, CarPlay, and sync milestones build on top of it.

## Outcome

- Tapping Record (or the mic) opens the dictation screen and, after permission is granted,
  starts capturing speech on device.
- Finalized speech lands in the note as paragraphs; the in-progress phrase shows live with a
  blinking caret. The waveform reacts to real microphone level.
- Pause halts capture without losing the note; resume continues the same note.
- Stopping saves the note as a Markdown file under the app's Documents directory and returns to
  the Stream list, where the new note appears at the top.
- The Stream list loads real saved notes (newest first), not mock data. Opening a note shows its
  saved paragraphs.
- If speech or microphone permission is denied or on-device recognition is unavailable, the
  screen shows a clear, friendly message instead of failing silently.

## Scope

In:
- On-device speech-to-text via `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`.
- Live transcript: finalized segments as paragraphs, current partial as live caret text.
- Start / stop / pause / resume of capture.
- Real microphone level driving the waveform (RMS of the audio buffer).
- `NoteStore` that saves and loads notes as Markdown files in `Documents/ThoughtStream/`.
- Stream list and note detail read real saved notes.
- Microphone + speech authorization, with denied/restricted/unavailable states handled in-app.
- Usage strings in `project.yml` (`NSMicrophoneUsageDescription`,
  `NSSpeechRecognitionUsageDescription`).
- XCTest coverage for `NoteStore` and note Markdown serialization.

Out (left for later milestones, model kept extensible for them):
- Mira control words / voice editing, CarPlay, iCloud sync, Siri shortcut, spelling overrides,
  a working settings screen. Note keeps room for these but implements none.
- Editing a saved note, deleting from the UI (delete may exist on the store but no UI needed).

## Approach

### Speech capture

- `SpeechDictationService` owns an `AVAudioEngine`, an `SFSpeechRecognizer`, and the current
  `SFSpeechRecognitionTask`. It exposes an async stream of events (partial text, finalized
  segment, audio level, error) that the view model consumes.
- Recognition request is `SFSpeechAudioBufferRecognitionRequest` with
  `requiresOnDeviceRecognition = true` and `shouldReportPartialResults = true`. The service
  checks `supportsOnDeviceRecognition` up front and surfaces an unavailable state if false.
- The input node tap appends buffers to the request and computes RMS for the waveform level.
- `AVAudioSession` is configured `.record` and activated on start, deactivated on stop/pause.
- Locale is the device locale, falling back to `en-US`.

### Continuous feed (task restart)

`SFSpeechRecognitionTask` has practical duration limits and ends on its own (a final result, a
timeout, or an error) even while the user is still talking. To keep dictation continuous, when a
task finishes while the engine is still running, the service tears down that task and starts a
fresh one against the same live audio, without stopping the engine or losing text already in the
note. Each finalized result is appended to the note as a paragraph before the restart, so no
committed text is lost across the seam. This restart is invisible to the user: they see one
continuous stream.

### Pause / resume

Pause stops the engine and the current task and ends the recognition request, but keeps the note
and its paragraphs in memory. Resume reconfigures the session, restarts the engine, and begins a
new task appending to the same note.

### Storage

- `NoteStore` persists each note as one `.md` file under
  `Documents/ThoughtStream/<id>.md` (directory created if missing).
- Format: YAML frontmatter (`id`, `title`, `created`) then the body, paragraphs joined by a
  blank line. Title is the first line of the first paragraph (trimmed, capped), or a generated
  "Note <date>" if empty.
- `NoteStore.save(note)` writes atomically; `NoteStore.loadAll()` parses every `.md` file and
  returns notes sorted newest first. Parsing is tolerant: a file without frontmatter still loads
  as a body-only note.
- `Note` gains Markdown (de)serialization and a `bodyMarkdown` helper; it stays a value type so
  later features (tags, source, edits) can add fields without breaking existing files.

### Wire-up

- `DictationViewModel` (`@MainActor`, `ObservableObject`) drives `DictationView`: it holds the
  committed paragraphs, the live partial, the recording/paused/denied state, and the audio
  level. It calls the speech service and the note store. The existing `DictationView` visual
  design (Live card, waveform, dock) is reused and bound to the view model; the waveform reads
  the real level.
- `StreamListView` loads from `NoteStore` on appear and refreshes after a dictation session
  saves. The Record button starts a new session; Stop saves and dismisses; the saved note
  appears at the top.

## Acceptance

- [ ] `cd ios && xcodegen generate` and build for `iPhone 17` simulator succeeds.
- [ ] App launches; first Record tap requests microphone and speech permission.
- [ ] With permission granted, capture starts; partial text shows live, finalized text becomes
      paragraphs; the waveform moves with input level.
- [ ] Pause halts capture and keeps the note; resume continues the same note.
- [ ] Stop saves a `.md` file under `Documents/ThoughtStream/` and returns to the Stream list
      with the new note at the top; reopening it shows the saved paragraphs.
- [ ] Denied/unavailable permission shows a clear in-app message, not a crash or silence.
- [ ] `NoteStore` unit tests (save/load round-trip, paragraph split/join, sorting, frontmatter
      parse) pass.
- [ ] Screenshot of the live dictation screen committed under `design/screenshots/`.
- [ ] README notes granting mic/speech permission on first run.
