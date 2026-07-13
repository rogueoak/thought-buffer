# Architecture

How the system is built and why.

## App project

- **SwiftUI, iPhone only, min iOS 17.0, Swift 5 language mode.** Swift 5 mode avoids strict
  concurrency friction for the shell; revisit when concurrency-heavy features land.
- **XcodeGen.** The project is generated from `ios/project.yml`; the `.xcodeproj` is gitignored
  so it never drifts or conflicts. Contributors run `xcodegen generate`. See README.
- **Bundle id** `com.rogueoak.thoughtstream`, display name "Thought Stream", publisher Rogue Oak.

## Source layout (`ios/ThoughtStream/`)

- `App/` - `ThoughtStreamApp` entry point. Roots to `StreamListView`; a `-uiScreen dictation`
  launch argument roots to `DictationView` instead, used only for screenshot tooling.
- `Models/` - `Note` (id, title, paragraphs, createdAt, derived snippet + paragraph count) with
  Markdown (de)serialization, plus `MockNotes` (sample data, used only by previews now). The
  value type stays small and tolerant of unknown frontmatter keys so later fields do not break
  files on disk.
- `Storage/` - `NoteStore` persists each note as `Documents/ThoughtStream/<id>.md` (YAML
  frontmatter + body). Thin and cache-free: the files are the source of truth. `loadAll` returns
  notes newest first.
- `Speech/` - `SpeechDictationService` owns the `AVAudioEngine`, `SFSpeechRecognizer`, and the
  current `SFSpeechRecognitionTask`. On-device only. Emits events (partial, finalized, level,
  failure). Auto-restarts a finished task on the same audio to keep dictation continuous. Also
  holds the Mira control-word pieces: `MiraCommandParser` (pure segment -> `MiraCommand?`),
  `MiraTextProcessor` (the `TextProcessor` that consumes commands), `SentenceTokenizer`
  (`NLTokenizer`-backed, for "remove the last sentence"), and `Speaker`/`SystemSpeaker`
  (`AVSpeechSynthesizer` text to speech for "read that back").
- `TextProcessor` seam - a finalized segment runs through `process`, which returns a
  `ProcessedSegment`: `.text` to commit, `.command` to execute and suppress, or `.drop`
  (reserved). `PassthroughTextProcessor` always returns `.text`; `MiraTextProcessor` returns
  `.command` when the parser matches. A future spelling-override processor composes here (parse
  for a command first, else transform text and return `.text`). The composition root
  (`AppDependencies.makeTextProcessor`) builds one per session.
- `ViewModels/` - `DictationViewModel` (`@MainActor ObservableObject`) is the one place with
  logic: it drives `DictationView` from the speech service, routes finalized segments through the
  `TextProcessor`, executes `MiraCommand`s (note mutations, new note save+reset, read-back), and
  saves through the store. For read-back it pauses capture, hands the last paragraph to the
  `Speaker`, and resumes when the speaker reports the utterance finished, so the spoken audio
  never feeds back into recognition.
- `Views/` - SwiftUI screens. `StreamListView` loads from `NoteStore`; `DictationView` binds to
  `DictationViewModel`; `NoteCard`, `NoteDetailView`, `SettingsView` stay presentational.
- `DesignSystem/` - vendored `Tokens.swift` from Canopy and a small `RelativeTime` helper.
- `Assets.xcassets/` - single 1024 universal `AppIcon`.

Tests live in `ios/ThoughtStreamTests/` (a `bundle.unit-test` target): `NoteStore`, `Note`
Markdown, `DictationViewModel` save/reload, the `MiraCommandParser` grammar, `SentenceTokenizer`,
and Mira command execution (note mutations, new note, read-back via a `Speaker` stub, and
`TextProcessor` result routing via stub capture/speaker doubles). The generated scheme runs them.

## Design tokens

River Mist tokens are authored in Canopy's `roots` package and vendored as generated Swift
(`DesignSystem/Tokens.swift`). Views use `CanopyColor` / `CanopySpacing` / `CanopyRadius` /
`CanopyFont`; no hardcoded hex. Colors are dynamic (light/dark) and adapt to the system
appearance automatically. Re-sync steps live in the README.
