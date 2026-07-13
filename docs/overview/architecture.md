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
- `Storage/` - two `NoteStoring` backends behind one seam, chosen at startup:
  - `NoteStore` persists each note as `Documents/ThoughtStream/<id>.md` (YAML frontmatter + body).
    Thin and cache-free: the files are the source of truth. `loadAll` returns notes newest first.
  - `ICloudNoteStore` writes the same `<id>.md` files (shared `Note` serialization) into the app's
    iCloud Drive ubiquity container `Documents/ThoughtStream/`, wrapping every read/write/delete in
    `NSFileCoordinator` so it never races the sync daemon. Selected only when iCloud resolves.
  - `NoteStoreFactory` is the single decision point: it resolves the ubiquity container via
    `UbiquityContainerProviding` (off the main actor - the lookup can block) and returns a
    `NoteStoreSelection` (store + `NoteStoreKind` .iCloud/.local + an observer for iCloud). The
    kind is carried through `AppDependencies` so a later Settings status can read it. Fallback is
    lossless: the local store is never touched and unavailable iCloud is a normal path, not an error.
  - `UbiquitousNoteObserving` (production `MetadataUbiquitousNoteObserver`, `NSMetadataQuery` over
    `NSMetadataQueryUbiquitousDocumentsScope`) enumerates iCloud notes, triggers downloads for
    not-yet-local items, and fires an `onChange` the Stream list observes to refresh on external
    edits / other-device syncs. Its pure mapping (`UbiquitousNoteMapping`) is unit-tested with
    stub items; the container provider and observer are protocols so selection and mapping are
    provable with no real iCloud.
  - The iCloud entitlement (iCloud Documents, container `iCloud.com.rogueoak.thoughtstream`) and
    the user-visible `NSUbiquitousContainers` Info.plist are declared in `ios/project.yml`;
    XcodeGen writes `ThoughtStream/ThoughtStream.entitlements` and `ThoughtStream/Info.plist`
    (both committed). The Simulator config disables code signing so the unsigned, teamless build
    stays green.
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
  never feeds back into recognition. `NoteStoreDriver` (headless, `@MainActor`, no SwiftUI) owns
  the notes list: it loads through the store on a detached task (the iCloud store's `loadAll()` can
  block on coordinated IO, so it must not run on the main actor) and, on iCloud, wires the
  `UbiquitousNoteObserving` observer once (`start`/`stop`, `onChange` -> reload) so the list
  refreshes on synced-in / external edits without restarting the query on navigation. The load and
  observe logic lives in the driver so any consumer can run it - a future headless CarPlay/Siri
  session as well as SwiftUI. `StreamFeed` (`@MainActor ObservableObject`) is a thin projection over
  the driver, republishing its `notes`/`didLoad` so a view can bind. `NoteStoring: Sendable`, so the
  detached load is sound under strict concurrency.
- `Views/` - SwiftUI screens. `StreamListView` drives a `StreamFeed` from a single `.task` and
  stays presentational; `DictationView` binds to `DictationViewModel`; `NoteCard`,
  `NoteDetailView`, `SettingsView` stay presentational.
- `DesignSystem/` - vendored `Tokens.swift` from Canopy and a small `RelativeTime` helper.
- `Assets.xcassets/` - single 1024 universal `AppIcon`.

Tests live in `ios/ThoughtStreamTests/` (a `bundle.unit-test` target): `NoteStore`, `Note`
Markdown, `DictationViewModel` save/reload, the `MiraCommandParser` grammar, `SentenceTokenizer`,
Mira command execution (note mutations, new note, read-back via a `Speaker` stub, and
`TextProcessor` result routing via stub capture/speaker doubles), the `ICloudNoteStore` coordinated
round-trip against a temp dir (plus cross-store file compatibility and the bare-markdown fallback
path), `NoteStoreFactory` selection and lossless fallback via a stub `UbiquityContainerProviding`,
the `UbiquitousNoteMapping` metadata-to-notes logic via stub items, and the driver's load +
observer wiring (start/stop, onChange -> reload, local no-observer path, no-reload-after-stop) via
stub store/observer through the `StreamFeed` projection.
The generated scheme runs them.

## Design tokens

River Mist tokens are authored in Canopy's `roots` package and vendored as generated Swift
(`DesignSystem/Tokens.swift`). Views use `CanopyColor` / `CanopySpacing` / `CanopyRadius` /
`CanopyFont`; no hardcoded hex. Colors are dynamic (light/dark) and adapt to the system
appearance automatically. Re-sync steps live in the README.
