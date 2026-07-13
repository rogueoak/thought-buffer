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
  launch argument roots to `DictationView` and a `-uiScreen settings` argument roots to a seeded
  `SettingsView`, both used only for screenshot tooling. Also the
  hands-free session-start seam and its entry points:
  - `SessionStarter` (protocol, one method `startNewSession()`) and `PendingSessionRoute` (its
    concrete `@MainActor ObservableObject`) are the single "start a new dictation session" seam. The
    Record button, the Siri App Intent, and CarPlay all request a start through it. The root
    (`StreamListView`) presents `DictationView` as a pure function of `startRequested`
    (`PendingSessionRoute.shouldPresent`, bound so a dismiss `consume()`s the route), so a start requested
    while backgrounded opens on appear and a re-request after a session ends re-opens - no lost-edge
    cases. `DictationView` begins capture in its `.task`. "Start a session" means "route to a fresh
    DictationView", so every entry point behaves identically and there is no parallel capture path.
    The route lives on `AppDependencies`; `AppDependencies.shared` / `.sessionStarter` is a narrow,
    documented process-wide bridge so App Intents and the CarPlay scene - which the system builds
    outside the SwiftUI tree - can reach the live route. Everything inside the view tree is still
    injected. A COLD hands-free launch (a Siri intent runs before `resolve()` finishes, so `shared`
    is nil) is handled by `ColdStartSessionStarter`, which records the request on a process-wide
    `PendingSessionRoute.pendingColdStart` latch that the route adopts the moment it is created, so
    the request that launched the app is never dropped.
  - `ThoughtStreamIntents.swift` - `StartThoughtStreamIntent` and `NewNoteIntent` (`AppIntent`,
    `openAppWhenRun`) call the starter (injected `SessionStarter`, defaulting to the live route), so
    they are unit-testable with a stub and never touch the UI. `ThoughtStreamShortcuts`
    (`AppShortcutsProvider`) registers the spoken phrases, each including `\(.applicationName)` per
    Apple's rule. This is the shippable hands-free-in-car path (Siri works in CarPlay without the
    CarPlay entitlement).
  - `CarPlaySceneDelegate.swift` - a `CPTemplateApplicationSceneDelegate` presenting a `CPListTemplate`
    with a "Start a thought stream" row that calls the shared starter. Wired via the
    `CPTemplateApplicationSceneSessionRoleApplication` role in the scene manifest
    (`ios/project.yml`), but GATED: no CarPlay entitlement is declared (Apple grants it only for
    specific app categories, not dictation / notes), so the system never creates the scene and the
    unsigned Simulator build and App Store build are unaffected. Ready the day Apple grants the
    entitlement; activating it needs the entitlement plus a CarPlay head unit / the CarPlay simulator.
- `Models/` - `Note` (id, title, paragraphs, createdAt, derived snippet + paragraph count) with
  Markdown (de)serialization, plus `MockNotes` (sample data, used only by previews now). The
  value type stays small and tolerant of unknown frontmatter keys so later fields do not break
  files on disk. Spec 0007 adds an optional `audioFileName` and per-paragraph `timings`
  (`ParagraphTiming` = start + duration), persisted as `audio:` and a compact `timings:` JSON array
  in frontmatter and written ONLY when a recording is present, so a text-only note serializes and
  parses byte-for-byte as before. Both are dropped on parse unless BOTH are present (a stray key is
  not a recording), keeping the tolerant-parse contract.
- `Storage/` - two `NoteStoring` backends behind one seam, chosen at startup:
  - `NoteStore` persists each note as `Documents/ThoughtStream/<id>.md` (YAML frontmatter + body).
    Thin and cache-free: the files are the source of truth. `loadAll` returns notes newest first.
  - `ICloudNoteStore` writes the same `<id>.md` files (shared `Note` serialization) into the app's
    iCloud Drive ubiquity container `Documents/ThoughtStream/`, wrapping every read/write/delete in
    `NSFileCoordinator` so it never races the sync daemon. Selected only when iCloud resolves.
  - Both stores manage the note's SIBLING audio recording (spec 0007): `audioURL(for:)` locates
    `<id>.m4a` beside `<id>.md`, `saveAudio(from:for:)` moves a captured temp recording into that
    slot with `FileProtection.completeUnlessOpen` (raw audio is more sensitive than text), and
    `deleteAudio(for:)` removes it - `delete(id:)` calls it so deleting a note never orphans a
    recording. `ICloudNoteStore` coordinates every audio operation through `NSFileCoordinator` like
    the note file. `NoteStoring` carries these with default no-ops so an in-memory test stub needs no
    audio. `AudioRetentionSweeper` deletes recordings older than the auto-delete window at launch
    (off the main actor), keeping the note text.
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
  - **Dual capture (spec 0007).** The single input tap tees each buffer to THREE sinks: the
    recognizer (as before), the waveform level, and - when recording is armed via
    `setRecordingEnabled(true)` before `start()` - a `RecordingWriter`. The writer is an off-main,
    lock-guarded (`@unchecked Sendable`) helper that appends buffers to a compressed AAC `.m4a`;
    it is created ONCE per session and kept across recognizer-task restarts AND pause/resume, so one
    continuous file spans the whole note (finalized only at `stop()`). `finalizedSegment` events now
    carry a `ParagraphTiming?`: the service tracks a per-request audio offset (elapsed frames /
    sample rate, read at each restart) and adds it to the segment's request-relative timestamp so a
    paragraph maps to an ABSOLUTE range in the recording even though the request clock resets each
    restart. `recordingURL()` exposes the temp file after `stop()` for the caller to adopt.
  - **Playback (spec 0007).** `AudioNotePlayer` (production `SystemAudioNotePlayer`, `AVAudioPlayer`)
    plays a recording seeked to a range (`play(url:from:duration:)`, a nil duration plays to the
    end; a timer stops a ranged play since `AVAudioPlayer` has no native stop-at). It mirrors
    `SystemSpeaker`'s session handling and `onFinish` so "read that back" routes through it and
    falls back to the `Speaker` when a note/paragraph has no audio - one record -> playback -> record
    handshake for both.
- `TextProcessor` seam - a finalized segment runs through `process`, which returns a
  `ProcessedSegment`: `.text` to commit, `.command` to execute and suppress, or `.drop`
  (reserved). `PassthroughTextProcessor` always returns `.text`; `MiraTextProcessor` returns
  `.command` when the parser matches (built with the configured control word);
  `SpellingOverrideProcessor` is text -> text, applying the user's whole-word, case-insensitive
  overrides via an `NSRegularExpression` word walk (so a substring is never corrupted).
  `CompositeTextProcessor` composes them in the required order: detect a command on the RAW
  segment FIRST (a control phrase must never be spelling-mangled), and only if it is not a command
  run the spelling processor and return `.text`. The composition root
  (`AppDependencies.makeTextProcessor`) builds one per session, reading the current control phrase
  and overrides off `SettingsStoring` at build time - so edits in Settings apply to the next
  session started, not one in flight.
- `Settings/` - `SettingsStoring` (protocol) and `UserDefaultsSettingsStore` (the local
  `UserDefaults`-backed impl, injected from the composition root) hold the control phrase
  (validated: trimmed, non-empty, sensible max length, else falls back to "Mira"), the ordered
  `SpellingOverride` list (persisted as JSON), and the `AudioRetention` policy (spec 0007:
  keep / transcript-only / auto-delete after N days, persisted as a small string tag so an unknown
  value falls back to `.keep`). Local only - no cloud sync, no per-note settings.
- `ViewModels/` - `DictationViewModel` (`@MainActor ObservableObject`) is the one place with
  logic: it drives `DictationView` from the speech service, routes finalized segments through the
  `TextProcessor`, executes `MiraCommand`s (note mutations, new note save+reset, read-back), and
  saves through the store. It keeps a `paragraphTimings` array in lockstep with `paragraphs`
  (spec 0007), so every note mutation (commit, remove-sentence/paragraph, fold-partial) updates
  both, and builds the saved `Note` with its recording (adopted from the service's temp file into
  the store) and timings at `finish()`. Mid-session "new note" saves the transcript only - the one
  continuous recording is finalized at Stop and belongs to the FINAL note. For read-back it prefers
  the ACTUAL recording of the last paragraph via `AudioNotePlayer` (its recorded range), falling
  back to the `Speaker` when there is no audio; either way it pauses capture and resumes on the
  shared `onFinish`, so the spoken audio never feeds back into recognition. `NotePlaybackModel`
  drives the detail view's simple play / stop of a saved note's recording. `NoteStoreDriver` (headless, `@MainActor`, no SwiftUI) owns
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
  `NoteDetailView` stay presentational. `SettingsView` edits the injected `SettingsStoring`
  instance directly (control-phrase field with validation hint, add/edit/delete override rows, a
  read-only storage-status row from `NoteStoreKind`).
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
stub store/observer through the `StreamFeed` projection, and the hands-free session-start seam (the
`PendingSessionRoute` request/consume lifecycle, both App Intents requesting a start through a stub
`SessionStarter`, `openAppWhenRun`, and the App Shortcuts being registered), plus Settings:
`UserDefaultsSettingsStore` persistence and control-phrase validation via an isolated defaults
suite, `SpellingOverrideProcessor` whole-word/case/multi-override/no-substring-corruption, and
`CompositeTextProcessor` ordering (a command is detected and not spelling-mangled; the configured
control word changes matching; a normal segment gets overrides).
The generated scheme runs them.

## Design tokens

River Mist tokens are authored in Canopy's `roots` package and vendored as generated Swift
(`DesignSystem/Tokens.swift`). Views use `CanopyColor` / `CanopySpacing` / `CanopyRadius` /
`CanopyFont`; no hardcoded hex. Colors are dynamic (light/dark) and adapt to the system
appearance automatically. Re-sync steps live in the README.
