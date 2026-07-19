# Architecture

How the system is built and why.

## App project

- **SwiftUI, iPhone only, min iOS 26.0, Swift 5 language mode.** iOS 26 is required for the
  on-device `SpeechAnalyzer` capture engine (spec 0002). Swift 5 mode avoids strict concurrency
  friction for the shell; revisit when concurrency-heavy features land.
- **XcodeGen.** The project is generated from `ios/project.yml`; the `.xcodeproj` is gitignored
  so it never drifts or conflicts. Contributors run `xcodegen generate`. See README.
- **Bundle id** `com.rogueoak.thoughtstream`, display name "Thought Stream", publisher Rogue Oak.

## Source layout (`ios/ThoughtStream/`)

- `App/` - `ThoughtStreamApp` entry point. Roots to `StreamListView`; a `-uiScreen dictation`
  launch argument roots to `DictationView` and a `-uiScreen settings` argument roots to a seeded
  `SettingsView`, both used only for screenshot tooling. On normal (non-`-uiScreen`) launches the
  root wraps `content` in a `ZStack` and overlays `LaunchCoverView` (spec 0012), gated by
  `@State showLaunchCover`; a `.task` holds it for a named minimum (`launchCoverHold`, ~2.5s) then
  cross-fades it out with `withAnimation(.easeOut)`, and a tap skips it early. The cover sits above
  the `dependencies == nil` themed-background state so there is no pre-resolution flash, and is
  skipped entirely for `-uiScreen` launches so screenshot tooling is unaffected. Also the
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
  - `CarPlaySceneDelegate.swift` - the CarPlay Audio surface (spec 0008): a
    `CPTemplateApplicationSceneDelegate` presenting a root `CPListTemplate` with a "Start a thought
    stream" row (calls the shared starter) plus one row per note that HAS a recording (title, date +
    duration), newest first, from a `RecordingsListModel` over the shared `NoteStoreDriver`, refreshed
    live on driver change. A row tap drives the shared `NotePlaybackController` and pushes
    `CPNowPlayingTemplate` (play / pause + skip buttons wired to the controller). The Start-row builder
    is a static, closure-driven factory (`makeStartItem(onStart:)`) so its routing is unit-testable
    without a connected scene. Wired via the `CPTemplateApplicationSceneSessionRoleApplication` role in
    the scene manifest (`ios/project.yml`), but GATED: no CarPlay entitlement is declared (Apple grants
    the CarPlay AUDIO entitlement only on approval), so the system never creates the scene and the
    unsigned Simulator build and App Store build are unaffected. Ready the day Apple grants the
    entitlement; activating it needs the entitlement plus a CarPlay head unit / the CarPlay simulator.
    See `docs/carplay-audio-entitlement-request.md`.
- `Models/` - `Note` (id, title, paragraphs, createdAt, derived snippet + paragraph count) with
  Markdown (de)serialization, plus `MockNotes` (sample data, used only by previews now). The
  value type stays small and tolerant of unknown frontmatter keys so later fields do not break
  files on disk. Spec 0007 adds an optional `audioFileName` and per-paragraph `timings`
  (`ParagraphTiming` = start + duration), persisted as `audio:` and a compact `timings:` JSON array
  in frontmatter and written ONLY when a recording is present, so a text-only note serializes and
  parses byte-for-byte as before. Both are dropped on parse unless BOTH are present (a stray key is
  not a recording), keeping the tolerant-parse contract. Spec 0009 makes the title editable:
  `deriveTitle` now returns the first SENTENCE of the first paragraph (via `SentenceTokenizer`), and a
  `hasCustomTitle` flag (frontmatter `titleCustom: true`, written only when true) distinguishes a
  user-set title from a derived one. Parsing still prefers a stored `title:` (files keep their title),
  and the flag only counts when a title is stored; it governs edit-time behavior - a non-custom note
  re-derives its title on a body edit, a custom note keeps it. `NoteDetailView` edits the title as a
  tappable header and `DictationViewModel` preserves a resumed note's custom title. `NoteDetailView`
  also takes a `startInEdit` flag (spec 0013): a brand-new keyboard note opens with the body editor
  focused and is tracked as unsaved until its first non-empty commit; a commit or leave with no title
  and no body calls `onDiscardEmpty` (delete any provisional save, pop the route) so no blank note is
  persisted.
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
  - Both stores are FOLDER-AWARE (spec 0010, PR A). A note can live in nested folders: it is a real
    subdirectory on disk (visible in Files / iCloud Drive), and a note in it lives at
    `directory/<folderPath>/<id>.md` with its `<id>.m4a` beside it. `Note.folderPath: [String]` is a
    LOCATION, not content - derived on load from the file's relative directory, consumed on save to
    place the file, and NEVER serialized into the Markdown, so a foldered note's `.md` is byte-
    identical to a top-level note's (old files and other apps are unaffected). Folder names are
    sanitized (`Note.sanitizedFolderName`: strip separators + leading dots, trim) so a name can never
    escape the tree. `loadAll` walks the tree recursively tagging each note's `folderPath`; the id-only
    operations (`delete`, `audioURL`, `saveAudio`, `deleteAudio`, `audioExists`) find a note's file by
    scanning the tree (`locateFile(id:)`), so the `NoteStoring` audio surface stays id-only and nothing
    downstream (the resolver, playback, recordings browser) changed. `save(note)` writes under
    `folderPath` creating dirs, and RELOCATES an existing `.md` + `.m4a` when the folder changed - a
    save with a new `folderPath` IS the move, and it leaves nothing behind. Folder ops
    (`folders(at:)`, `createFolder`, `renameFolder`, `deleteFolder` - a recursive cascade over notes +
    recordings + subfolders) round out the surface. `ICloudNoteStore` wraps every tree walk, move,
    cascade, and dir-create in `NSFileCoordinator` exactly as the file IO. `NoteStoring` defaults the
    folder methods to no-ops (like the audio methods) so stubs keep compiling. `NoteSortOrder`
    (newest/oldest/titleAZ/titleZA) is a pure, stable sort over `[Note]` (PR B wires the persisted
    toolbar menu). `DictationViewModel` saves the note FILE before adopting its recording, so the
    `.m4a` lands beside the `.md` in the note's folder; a fresh note is created at the top level and
    filed afterward, a resumed note re-saves in the folder it already lives in.
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
- `Speech/` - `SpeechAnalyzerService` owns the `AVAudioEngine` and the iOS 26 `SpeechAnalyzer` +
  `SpeechTranscriber` (spec 0002). On-device only. Emits events (partial, finalized, level, failure)
  behind the unchanged `SpeechCaptureService` protocol, so the view model and its tests did not
  change. The transcriber reports VOLATILE results (in-progress, mapped to `.partial`) and FINALIZED
  results (stable, immutable, each mapped to a `.finalizedSegment` with its audio `CMTimeRange`), so
  there is NO utterance-boundary guessing: one finalized result is one paragraph. The old heuristic
  layer it replaced (`isReset`, `strippingCommittedPrefix`, `committedThisTask`, `resolveEnd`,
  `resolveTaskEndCommit`, task restart) is gone. The mic is tapped so buffers can be teed to the
  recording writer and level meter and converted into the analyzer's format for an
  `AsyncStream<AnalyzerInput>`. Pause finalizes the analyzer so the in-progress utterance commits;
  stop stops emitting and lets the view model fold the last live partial. The on-device model is
  installed once via `AssetInventory` during authorization (a model download, not audio leaving the
  device). Also holds the Mira control-word pieces: `MiraCommandParser` (pure segment ->
  `MiraParseResult`: `.text`, or `.split(preText:command:)` at the FIRST control word found anywhere),
  `MiraTextProcessor` (the `TextProcessor` that splits at commands), `SentenceTokenizer`
  (`NLTokenizer`-backed, for "remove the last sentence"), and `Speaker`/`SystemSpeaker`
  (`AVSpeechSynthesizer` text to speech for "read that back"). `SystemSpeaker` sets each utterance's
  voice to the best installed one for the user's language (spec 0014) via the pure `VoiceSelector`
  (`bestVoiceIdentifier(from:languageCode:)`, premium > enhanced > default, exact-region preferred,
  nil -> system default), resolved once from `AVSpeechSynthesisVoice.speechVoices()`.
  - **Dual capture (spec 0007).** The single input tap tees each buffer to THREE sinks: the analyzer
    (converted to its format), the waveform level, and - when recording is armed via
    `setRecordingEnabled(true)` before `start()` - a `RecordingWriter`. The writer is an off-main,
    lock-guarded (`@unchecked Sendable`) helper that appends buffers to a compressed AAC `.m4a`;
    it is created ONCE per session and kept across pause/resume, so one continuous file spans the
    whole note (finalized only at `stop()`). The tap tees to the writer BEFORE the analyzer so a
    resume offset is not under-counted. `finalizedSegment` events carry a `ParagraphTiming?`: a
    finalized result's audio `CMTimeRange` is relative to the analysis start, so the service adds an
    offset (recording seconds elapsed at analysis start, captured at each resume) via the pure,
    unit-tested `RecordingTiming.absolute` to map a paragraph to an ABSOLUTE range in the one
    continuous recording. `recordingURL()` exposes the temp file for adoption and is documented as
    finalized only after `stop()`;
    `discardRecording()` removes an orphan (even a zero-frame one).
  - **Playback (spec 0007, extended in 0008).** `AudioNotePlayer` (production `SystemAudioNotePlayer`,
    `AVAudioPlayer`) plays a recording seeked to a range (`play(url:from:duration:)`, a nil duration
    plays to the end; a timer stops a ranged play since `AVAudioPlayer` has no native stop-at),
    mirroring `SystemSpeaker`'s session handling and `onFinish`. Spec 0008 adds `pause()` / `resume()`
    / `currentTime` / `seek(to:)` so the shared controller can pause, resume, publish elapsed, and
    relative-skip. IN-SESSION "read that back" stays on the text-to-speech `Speaker`: the live `.m4a`
    is still open for writing (finalized only at `stop()`), so there is no finalized file to play
    mid-session; both share the `readBackDidFinish` resume handshake.
  - **System Now Playing (spec 0008).** `NowPlayingCenter.swift` holds the media-center seam:
    `NowPlayingInfo` (title / duration / elapsed / rate value), `NowPlayingInfoWriting` (production
    `SystemNowPlayingInfoWriter` over `MPNowPlayingInfoCenter`), and `RemoteCommandRegistering`
    (production `SystemRemoteCommandRegistrar` over `MPRemoteCommandCenter`, wiring
    play / pause / toggle / stop / skip-forward / skip-back at a 15s interval). Both are protocols so
    the playback controller is unit-testable with spies and no real media center. Adding `audio` to
    `UIBackgroundModes` (Info.plist) makes background playback + lock-screen Now Playing work; it needs
    no entitlement.
- `TextProcessor` seam - a finalized segment runs through `process`, which returns a
  `ProcessedSegment`: `.text` to commit, `.split(preText:command:)` (feedback 0006: the dictation
  before the control word plus a command outcome - `.command` to execute or `.unrecognizedCommand` to
  drop with a chip), or `.drop` (reserved). `PassthroughTextProcessor` always returns `.text`;
  `MiraTextProcessor` returns `.split` when the parser finds the control word anywhere (built with the
  configured control word); `SpellingOverrideProcessor` is text -> text, applying the user's
  whole-word, case-insensitive overrides via an `NSRegularExpression` word walk (so a substring is
  never corrupted). `CompositeTextProcessor` composes them in the required order: split at the control
  word on the RAW segment FIRST (the command portion must never be spelling-mangled or transcribed),
  and apply spelling overrides ONLY to the pre-keyword dictation (or the whole segment when no control
  word is present). The composition root
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
  continuous recording is finalized at Stop and belongs to the FINAL note. Resuming a note seeds its
  id, paragraphs, timings, folder, and (when present) its existing recording; `saveCurrentNote`
  prefers a NEWLY captured recording when armed, else keeps the existing one. So a text-only note
  recorded into with `recordsAudio: true` (spec 0013 - `StreamListView`'s note-page record action
  passes `!note.hasAudio && audioRetention.recordsAudio`) adopts the new audio: the newly spoken tail
  keeps its real range and the original typed paragraphs get zero-length timing placeholders (TTS on
  playback). A note that already has audio keeps `recordsAudio: false` (text-only append, original
  recording preserved). In-session read-back
  speaks via the `Speaker` (the live recording is not yet finalized); it pauses capture and resumes
  on `readBackDidFinish`, so the spoken audio never feeds back into recognition. `NotePlaybackModel`
  drives the detail view's simple play / stop of a SAVED note's recording via `AudioNotePlayer` -
  where the file is finalized - and hides the affordance (through `NoteStoring.audioExists`) when a
  note has no readable recording. `NoteStoreDriver` (headless, `@MainActor`, no SwiftUI) owns
  the notes list: it loads through the store on a detached task (the iCloud store's `loadAll()` can
  block on coordinated IO, so it must not run on the main actor) and, on iCloud, wires the
  `UbiquitousNoteObserving` observer once (`start`/`stop`, `onChange` -> reload) so the list
  refreshes on synced-in / external edits without restarting the query on navigation. The load and
  observe logic lives in the driver so any consumer can run it - the CarPlay browser as well as
  SwiftUI. `StreamFeed` (`@MainActor ObservableObject`) is a thin projection over the driver,
  republishing its `notes`/`didLoad` so a view can bind. `NoteStoring: Sendable`, so the detached
  load is sound under strict concurrency.
  - **Folder navigation model (spec 0010, PR B).** The driver/feed also expose the folder seams -
    `childFolders(at:)`, `createFolder`/`renameFolder`/`deleteFolder`, and `move(_:to:)` (a re-save with
    a new `folderPath`) - each on a detached task then a reload, so the whole notes list stays the one
    source. The list PROJECTION is pure and testable in `FolderListModel` (`@MainActor`): it takes the
    driver's flat `notes`, the child folder names the store reported at a path, the current path, and the
    chosen `NoteSortOrder`, and returns an ordered `[FolderListItem]` (`.folder(name:path:)` or
    `.note`). Notes are filtered to those whose `folderPath` EQUALS the current path; each folder gets a
    `SortKey` whose date is its newest descendant note (recursively, `.distantPast` when empty) and whose
    title is its name, so folders and notes interleave through the SAME `NoteSortOrder.areInIncreasingOrder`
    comparator - no second copy of the ordering. `FolderMoveTargets` is a second pure builder: driven by a
    `children` closure (`store.folders(at:)`), it flattens the tree pre-order with depth for the
    move-to-folder picker, so an empty folder (never in any note's `folderPath`) is still offered.
  - **Shared playback + CarPlay browser (spec 0008).** `NotePlaybackController` (`@MainActor
    ObservableObject`) is the ONE audio path: it owns an `AudioNotePlayer`, an `AudioURLResolving`
    (lazy off-main resolution at play time, as 0007's model did), and the Now Playing / remote-command
    seams, exposing play / pause / resume / stop / skip and one writer of `MPNowPlayingInfoCenter`.
    Both the phone detail view (through `NotePlaybackModel`, now a thin projection over the controller
    that keeps the simple play / stop button) and the CarPlay scene drive it. `RecordingsListModel`
    (`@MainActor`, callback-observable like the driver, not SwiftUI - the CarPlay delegate is UIKit)
    projects `NoteStoreDriver.notes` to only notes with a recording, newest first, each with a
    formatted duration (`recordingDuration` = the tail of the last-ending timing range), and refreshes
    on driver change; its duration formatting is a pure, unit-tested static.
- `Views/` - SwiftUI screens. `StreamListView` is the ROOT of the Thoughts `NavigationStack` whose
  path is an enum route `StreamRoute { case folder([String]); case note(Note); case newNote(Note) }`:
  it owns the shared session/settings/playback wiring and the sort-order state, and renders
  `FolderContentsView(path: [])` as the root with a `navigationDestination` for the routes.
  `FolderContentsView` renders the same folder-list screen at ANY path (so a pushed `.folder` recurses
  into another instance), projecting its rows through `FolderListModel`; it owns the folder-CRUD alerts,
  the sort menu, swipe/context actions, the `MoveToFolderSheet`, and the empty states. Its toolbar's
  compose button (spec 0013) calls `onNewNote(currentPath)`, and `StreamListView` pushes a `.newNote`
  route seeded with a fresh `Note(title: "", paragraphs: [], folderPath: currentPath)`. `FolderRow` mirrors `NoteCard`'s surface with a folder
  glyph, item count, and chevron. `DictationView` binds to `DictationViewModel`; `NoteCard`,
  `NoteDetailView` stay presentational. `SettingsView` edits the injected `SettingsStoring`
  instance directly (control-phrase field with validation hint, add/edit/delete override rows, a
  read-only storage-status row from `NoteStoreKind`). The chosen `NoteSortOrder` persists through
  `SettingsStoring.noteSortOrder` (a stable string tag; unknown -> `.newest`).
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
control word changes matching; a normal segment gets overrides), plus the CarPlay Audio surface
(spec 0008): the shared `NotePlaybackController` (play / pause / resume / stop / skip via a stubbed
player, `MPNowPlayingInfoCenter` populated via a spy, remote-command handlers calling back into the
controller via a spy), the `RecordingsListModel` (audio-only filter, newest-first order, duration
formatting, and driver-change -> list refresh via a stub store + observer), and the CarPlay Start row
routing through the shared `SessionStarter`, plus the folder UI models (spec 0010, PR B):
`FolderListModel` (filter-by-path, folder/note interleave for each sort order, folder date = newest
descendant recursively, empty-folder-to-the-end), `FolderMoveTargets` (pre-order + depth flatten,
empty folder still offered, sibling A-Z, subtree exclusion), and `noteSortOrder` persistence /
unknown-tag fallback in `UserDefaultsSettingsStore`.
The generated scheme runs them.

## Design tokens

River Mist tokens are authored in Canopy's `roots` package and vendored as generated Swift
(`DesignSystem/Tokens.swift`). Views use `CanopyColor` / `CanopySpacing` / `CanopyRadius` /
`CanopyFont`; no hardcoded hex. Colors are dynamic (light/dark) and adapt to the system
appearance automatically. Re-sync steps live in the README.
