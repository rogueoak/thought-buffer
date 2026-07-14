# 0002 - On-device dictation MVP

## Problem

The themed shell (spec 0001) ships a mock dictation screen: a timer reveals a canned string,
the waveform is decorative, and nothing is saved. To be a real notes app, Thought Stream needs
to turn speech into text on the device and keep it. This milestone makes dictation real: you
tap Record, talk, and your words stream into a note that saves as a Markdown file and shows up
in the Stream list, all on device with no network.

Who it is for: the first on-device testers, who need to prove capture-to-save works before the
voice-editing, CarPlay, and sync milestones build on top of it.

Capture is built on Apple's iOS 26 `SpeechAnalyzer` / `SpeechTranscriber`. An earlier build used
`SFSpeechRecognizer` + an `AVAudioEngine` tap and grew a set of utterance-boundary heuristics to
work around that API (accumulation, resets, duplicate paragraphs); the current implementation
deletes those heuristics at the source. This spec describes dictation as it stands.

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
- On-device speech-to-text via iOS 26 `SpeechAnalyzer` + `SpeechTranscriber`, which reports
  explicit VOLATILE (in-progress) and FINALIZED (stable, immutable) results with precise audio
  time ranges. Minimum deployment target is iOS 26; there is no dual path.
- On first run (or a new locale) the transcriber's on-device model asset is installed via
  `AssetInventory`; a "preparing on-device speech" state is surfaced while it downloads.
- Live transcript: each FINALIZED result is one committed paragraph, the current VOLATILE result
  is live caret text. No reset guessing, no task-restart heuristics.
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

- `SpeechAnalyzerService` (conforming to the `SpeechCaptureService` protocol - the seam the view
  model and its tests depend on) exposes an async stream of `SpeechCaptureEvent` values (partial
  text, finalized segment with a time range, audio level, failure) that the view model consumes.
- It is built on `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)`
  configured for volatile-result reporting and audio-time-range attributes, driving a
  `SpeechAnalyzer(modules: [transcriber])` fed an `AsyncStream` of analyzer inputs.
- The mic is still tapped via `AVAudioEngine`: one tap, three sinks - it computes RMS for the
  waveform level, forwards converted buffers to the analyzer input stream, and leaves room for the
  recording writer that a later milestone tees in. Any needed `AVAudioPCMBuffer` format conversion
  into the analyzer's input format happens on the tap.
- `AVAudioSession` is configured `.record` and activated on start, deactivated on stop/pause.
- Locale is the device locale, falling back to `en-US`.

Event mapping (protocol unchanged):

- transcriber VOLATILE result -> `.partial(text)` (drives the live caret; replaced by the next).
- transcriber FINALIZED result -> `.finalizedSegment(text, range:)`, where `range` is the result's
  audio `CMTimeRange` mapped to a paragraph timing (start/duration in seconds, offset to recording
  start) via a pure, unit-tested `CMTimeRange -> ParagraphTiming` conversion. One finalized result
  is one committed paragraph.
- mic level -> `.level(Float)`; setup / stream failure -> `.failure(SpeechCaptureError)`.

### Continuous, boundary-driven finalization

The analyzer runs continuously and reports its own stable boundaries, so there is no task-restart
loop and no boundary heuristic. Because finalized results are stable and non-overlapping, each is a
clean paragraph the view model commits directly, and the live volatile result is shown as the
partial. This removes the whole class of accumulation / reset / duplicate-paragraph problems the
earlier `SFSpeechRecognizer`-based build had to guess around (`isReset`, `normalizedForReset`,
`strippingCommittedPrefix`, `committedThisTask`, `resolveEnd`, `restartTaskIfCapturing`, and the
tests that guarded them are gone).

### Model asset installation

`SpeechTranscriber` needs the locale's on-device model asset. If it is installed, capture starts
immediately; if not, the service kicks off installation via `AssetInventory` / the transcriber's
installation request and surfaces a "preparing on-device speech" state (the same denied /
unavailable card path, extended) until it is ready. An unsupported locale or an offline install
failure maps to a clear `SpeechCaptureError`. The one-time model download is provisioning only -
transcription runs fully on device and no audio or text leaves the phone.

### Pause / resume

Pause stops the engine and finishes the analyzer input, then FINALIZES the analyzer so the
in-progress utterance is committed as a paragraph (with its timing) before the session is released;
the note and its paragraphs stay in memory. The finalize + result drain runs on the captured session
so a concurrent resume never races it, and is bounded by a watchdog so a stuck results stream cannot
wedge teardown. Resume reconfigures the session, restarts the engine, and feeds a fresh analyzer
input stream that appends to the same note - serialized to wait for any in-flight pause teardown
first. Stop, by contrast, cancels the results stream (the view model folds the last live partial into
the note) so a late finalized result never appends a duplicate after the note is saved.

Speech + microphone authorization is unchanged (`SFSpeechRecognizer.requestAuthorization` /
`AVAudioApplication.requestRecordPermission`); the Speech authorization gate still governs
`SpeechTranscriber`.

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

- [ ] `ios/project.yml` sets `deploymentTarget` 26.0; `cd ios && xcodegen generate` and build for
      the `iPhone 17` simulator succeeds.
- [ ] App launches; first Record tap requests microphone and speech permission.
- [ ] With permission granted, capture starts; the volatile result shows live and each finalized
      result becomes one paragraph (no duplicates / resets); the waveform moves with input level.
- [ ] The pure mappers pass in CI: `CMTimeRange -> ParagraphTiming` conversion,
      volatile/finalized -> event mapping, and asset-state -> `SpeechCaptureError` mapping.
- [ ] On first run (or a new locale) the model asset installs and a "preparing on-device speech"
      state shows until it is ready; an unsupported locale / offline failure shows a clear message.
- [ ] Pause halts capture and keeps the note; resume continues the same note.
- [ ] Stop saves a `.md` file under `Documents/ThoughtStream/` and returns to the Stream list
      with the new note at the top; reopening it shows the saved paragraphs.
- [ ] Denied/unavailable permission shows a clear in-app message, not a crash or silence.
- [ ] `NoteStore` unit tests (save/load round-trip, paragraph split/join, sorting, frontmatter
      parse) pass.
- [ ] Screenshot of the live dictation screen committed under `design/screenshots/`.
- [ ] README notes granting mic/speech permission on first run and that the on-device language
      model may download once (provisioning only; transcription stays on device).
