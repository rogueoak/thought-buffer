# 0002 - Dictation MVP build plan

Source: `docs/specs/0002-dictation-mvp.md`.

## Steps

1. **Model + storage**
   - `Models/Note.swift`: add Markdown (de)serialization (`markdown`, `init(markdown:filename:)`),
     `bodyMarkdown`, title derivation, `updatedAt`/extensibility notes. Keep value type.
   - `Storage/NoteStore.swift`: `Documents/ThoughtStream/` dir; `save`, `loadAll` (newest first),
     `delete`. Atomic writes, tolerant parse.

2. **Speech**
   - `Speech/SpeechDictationService.swift`: `AVAudioEngine` + `SFSpeechRecognizer` +
     `SFSpeechAudioBufferRecognitionRequest` (on-device). Authorization, availability check,
     RMS level, task auto-restart, pause/resume, clean session teardown. Emits events.

3. **View model**
   - `ViewModels/DictationViewModel.swift`: `@MainActor ObservableObject`. Drives state:
     paragraphs, partial, level, phase (idle/recording/paused/denied/unavailable). Talks to
     service + store. `finish()` saves and returns the note.

4. **Views**
   - `DictationView.swift`: bind to view model, real waveform level, permission states, Stop.
   - `StreamListView.swift`: load from `NoteStore`, refresh after save, present dictation.
   - `App`: keep screenshot launch arg (mock preview mode ok).

5. **Config**
   - `project.yml`: usage strings; add test target `ThoughtStreamTests`.

6. **Tests**
   - `ThoughtStreamTests/NoteStoreTests.swift`, `NoteMarkdownTests.swift`.

7. **Build + verify**
   - `xcodegen generate`; build iPhone 17; iterate to BUILD SUCCEEDED. Launch, screenshot.

8. **Docs**
   - README first-run permission note; update `docs/overview/` (features, architecture,
     learnings).
