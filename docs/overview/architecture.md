# Architecture

How the system is built and why.

## App project

- **SwiftUI, iPhone AND iPad, min iOS 26.0, Swift 5 language mode.** iOS 26 is required for the
  on-device `SpeechAnalyzer` capture engine (spec 0002). Swift 5 mode avoids strict concurrency
  friction for the shell; revisit when concurrency-heavy features land. As of spec 0022 the
  `TARGETED_DEVICE_FAMILY` is `1,2` (iPhone + iPad): the Thoughts root is an ADAPTIVE navigation
  container - a `NavigationSplitView` on regular width (iPad, iPhone landscape where it fits), the
  `NavigationStack` on compact (iPhone portrait) - chosen by the pure `StreamContainer.decide`. iPad
  supports all orientations; iPhone stays portrait-only (`UISupportedInterfaceOrientations~ipad`).
- **XcodeGen.** The project is generated from `ios/project.yml`; the `.xcodeproj` is gitignored
  so it never drifts or conflicts. Contributors run `xcodegen generate`. See README.
- **Bundle id** `com.rogueoak.thoughtstream`, display name "Thought Stream", publisher Rogue Oak.
- **Paired watchOS app (spec 0023).** A `ThoughtStreamWatch` watchOS app target (deployment target 26.0),
  companion bundle id `com.rogueoak.thoughtstream.watchkitapp`, embedded in the iOS app. It quick-captures
  audio on the wrist and syncs it to the phone (which transcribes and files it) and browses recent thoughts.
  See "Shared source and the watch target" below.

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
  - `ThoughtStreamIntents.swift` - `StartThoughtStreamIntent` and `NewThoughtIntent` (`AppIntent`,
    `openAppWhenRun`) call the starter (injected `SessionStarter`, defaulting to the live route), so
    they are unit-testable with a stub and never touch the UI. `ThoughtStreamShortcuts`
    (`AppShortcutsProvider`) registers the spoken phrases, each including `\(.applicationName)` per
    Apple's rule. This is the shippable hands-free-in-car path (Siri works in CarPlay without the
    CarPlay entitlement).
  - `CarPlaySceneDelegate.swift` - the CarPlay Audio surface (spec 0008): a
    `CPTemplateApplicationSceneDelegate` presenting a root `CPListTemplate` with a "Start a thought
    stream" row (calls the shared starter) plus one row per thought that HAS a recording (title, date +
    duration), newest first, from a `RecordingsListModel` over the shared `ThoughtStoreDriver`, refreshed
    live on driver change. A row tap drives the shared `ThoughtPlaybackController` and pushes
    `CPNowPlayingTemplate` (play / pause + skip buttons wired to the controller). The Start-row builder
    is a static, closure-driven factory (`makeStartItem(onStart:)`) so its routing is unit-testable
    without a connected scene. Wired via the `CPTemplateApplicationSceneSessionRoleApplication` role in
    the scene manifest (`ios/project.yml`), but GATED: no CarPlay entitlement is declared (Apple grants
    the CarPlay AUDIO entitlement only on approval), so the system never creates the scene and the
    unsigned Simulator build and App Store build are unaffected. Ready the day Apple grants the
    entitlement; activating it needs the entitlement plus a CarPlay head unit / the CarPlay simulator.
    See `docs/carplay-audio-entitlement-request.md`.
- `Models/` - `ThoughtSearch` (spec 0021) is the pure, unit-testable full-text match seam over the thoughts
  the store already loads (no separate index): `matches(_:query:)` tests whether a thought's title OR any
  body paragraph contains the query as a substring, case- and diacritic-insensitively (both sides folded
  via `.folding(options: [.caseInsensitive, .diacriticInsensitive])`); `results(in:query:)` returns the
  flat, order-preserving GLOBAL list across all folders; `isActive(_:)` gates results-vs-normal on a
  non-whitespace query. No SwiftUI import - the folder and thought-detail views are thin callers.
- `Models/` - `ThoughtFind` + `ThoughtFindNavigator` (spec 0025) are the pure, unit-testable IN-THOUGHT
  find - the per-thought counterpart to `ThoughtSearch` (which decides WHICH thoughts match, globally).
  `ThoughtFind.matches(title:paragraphs:query:)` returns the ordered `Match` locations within ONE thought
  (a `Region` = `.title` or `.paragraph(Int)`, plus a `Range<Int>` of CHARACTER OFFSETS into that region's
  ORIGINAL text - integer offsets, not a `String.Index`, which is valid only against its producing string
  and would be undefined against the title the view re-derives each render), reusing `ThoughtSearch`'s case-
  and diacritic-insensitive folding OPTIONS (one shared `ThoughtFind.foldingOptions` constant, so the two
  seams cannot drift) but folding PER CHARACTER so each range maps back to the original string (a
  length-changing whole-string fold would misplace the highlight; the two AGREE for length-preserving folds
  and diverge only for the rare ligature / 'sz' case, documented on `fold`); an empty/whitespace query
  yields no matches, matches within a region are left-to-right and non-overlapping, and the order is
  title-then-paragraphs-in-order. `ThoughtFindNavigator` holds the
  current-match index (starts on the first match), steps next/previous WRAPPING, and formats the "N of M"
  `countLabel`; `Region.scrollID` is the stable `ScrollViewReader` anchor. `ThoughtDetailView` is a thin
  caller: its bottom-bar search field drives this find (superseding spec 0021's "detail search routes to
  the global results"; the list / folder screens stay GLOBAL), mapping a match to an AttributedString
  highlight (Canopy `warning` background, the CURRENT match emphasized bold + `warningForeground`) and
  scrolling the current match's region into view. Find and edit are mutually exclusive (entering an editor
  clears the find; the bar hides while editing), and find state resets when the thought is left (the query
  is local `@State`). The AttributedString rendering and the scroll are device-verified; the
  match/nav/count/anchor logic is unit-tested (`ThoughtFindTests`).
- `Models/` - `Thought` (id, title, paragraphs, createdAt, derived snippet + paragraph count) with
  Markdown (de)serialization, plus `MockThoughts` (sample data, used only by previews now). The
  value type stays small and tolerant of unknown frontmatter keys so later fields do not break
  files on disk. Spec 0007 adds an optional `audioFileName` and per-paragraph `timings`
  (`ParagraphTiming` = start + duration), persisted as `audio:` and a compact `timings:` JSON array
  in frontmatter and written ONLY when a recording is present, so a text-only thought serializes and
  parses byte-for-byte as before. Both are dropped on parse unless BOTH are present (a stray key is
  not a recording), keeping the tolerant-parse contract. Spec 0009 makes the title editable:
  `deriveTitle` now returns the first SENTENCE of the first paragraph (via `SentenceTokenizer`), and a
  `hasCustomTitle` flag (frontmatter `titleCustom: true`, written only when true) distinguishes a
  user-set title from a derived one. Parsing still prefers a stored `title:` (files keep their title),
  and the flag only counts when a title is stored; it governs edit-time behavior - a non-custom thought
  re-derives its title on a body edit, a custom thought keeps it. `ThoughtDetailView` edits the title as a
  tappable header and `DictationViewModel` preserves a resumed thought's custom title. `ThoughtDetailView`
  also takes a `startInEdit` flag (spec 0013): a brand-new keyboard thought opens with the body editor
  focused and is tracked as unsaved until its first non-empty commit; a commit or leave with no title
  and no body calls `onDiscardEmpty` (delete any provisional save, pop the route) so no blank thought is
  persisted.
- `Storage/` - two `ThoughtStoring` backends behind one seam, chosen at startup:
  - `ThoughtStore` persists each thought as `Documents/ThoughtStream/<id>.md` (YAML frontmatter + body).
    Thin and cache-free: the files are the source of truth. `loadAll` returns thoughts newest first.
  - `ICloudThoughtStore` writes the same `<id>.md` files (shared `Thought` serialization) into the app's
    iCloud Drive ubiquity container `Documents/ThoughtStream/`, wrapping every read/write/delete in
    `NSFileCoordinator` so it never races the sync daemon. Selected only when iCloud resolves.
  - Both stores manage the thought's SIBLING audio recording (spec 0007): `audioURL(for:)` locates
    `<id>.m4a` beside `<id>.md`, `saveAudio(from:for:)` moves a captured temp recording into that
    slot with `FileProtection.completeUnlessOpen` (raw audio is more sensitive than text), and
    `deleteAudio(for:)` removes it - `delete(id:)` calls it so deleting a thought never orphans a
    recording. `ICloudThoughtStore` coordinates every audio operation through `NSFileCoordinator` like
    the thought file. `ThoughtStoring` carries these with default no-ops so an in-memory test stub needs no
    audio. `AudioRetentionSweeper` deletes recordings older than the auto-delete window at launch
    (off the main actor), keeping the thought text.
  - Both stores support RECOVERABLE delete (spec 0020). `softDelete(id:)` MOVES a thought's `<id>.md`
    (and sibling `<id>.m4a`) into a hidden `.trash/<id>/` directory INSIDE the store root - never
    removing them - and returns a lightweight `DeletedThought` token (id + former `folderPath` +
    filenames) sufficient to `restore`. `restore(_:)` moves the files back to the former folder, or to
    ROOT when that folder is gone (a `RestoredThought` records `landedAtRoot`, never a failure);
    `purge(_:)` and `purgeAllTrash()` permanently remove trashed files (undo-window close, launch
    sweep). The trash is hidden (leading dot) so `loadAll`/`locateFile` (which skip hidden files) never
    surface a trashed thought, and a restore's destination is gated by `resolvedRestoreDirectory` (at or
    below root) so a crafted former-folder path can never escape the tree - the same path-safety posture
    as `resolvedFolderDirectory`. `ICloudThoughtStore` wraps every trash move/delete/existence-check in
    `NSFileCoordinator` exactly like the rest of its IO. `ThoughtStoring` defaults `softDelete` to the
    hard `delete` and the rest to no-ops so stubs keep compiling.
  - Both stores are FOLDER-AWARE (spec 0010, PR A). A thought can live in nested folders: it is a real
    subdirectory on disk (visible in Files / iCloud Drive), and a thought in it lives at
    `directory/<folderPath>/<id>.md` with its `<id>.m4a` beside it. `Thought.folderPath: [String]` is a
    LOCATION, not content - derived on load from the file's relative directory, consumed on save to
    place the file, and NEVER serialized into the Markdown, so a foldered thought's `.md` is byte-
    identical to a top-level thought's (old files and other apps are unaffected). Folder names are
    sanitized (`Thought.sanitizedFolderName`: strip separators + leading dots, trim) so a name can never
    escape the tree. `loadAll` walks the tree recursively tagging each thought's `folderPath`; the id-only
    operations (`delete`, `audioURL`, `saveAudio`, `deleteAudio`, `audioExists`) find a thought's file by
    scanning the tree (`locateFile(id:)`), so the `ThoughtStoring` audio surface stays id-only and nothing
    downstream (the resolver, playback, recordings browser) changed. `save(thought)` writes under
    `folderPath` creating dirs, and RELOCATES an existing `.md` + `.m4a` when the folder changed - a
    save with a new `folderPath` IS the move, and it leaves nothing behind. Folder ops
    (`folders(at:)`, `createFolder`, `renameFolder`, `deleteFolder` - a recursive cascade over thoughts +
    recordings + subfolders) round out the surface. `ICloudThoughtStore` wraps every tree walk, move,
    cascade, and dir-create in `NSFileCoordinator` exactly as the file IO. `ThoughtStoring` defaults the
    folder methods to no-ops (like the audio methods) so stubs keep compiling. `ThoughtSortOrder`
    (newest/oldest/titleAZ/titleZA) is a pure, stable sort over `[Thought]` (PR B wires the persisted
    toolbar menu). `DictationViewModel` saves the thought FILE before adopting its recording, so the
    `.m4a` lands beside the `.md` in the thought's folder; a fresh thought is created at the top level and
    filed afterward, a resumed thought re-saves in the folder it already lives in.
  - `ThoughtStoreFactory` is the single decision point: it resolves the ubiquity container via
    `UbiquityContainerProviding` (off the main actor - the lookup can block) and returns a
    `ThoughtStoreSelection` (store + `ThoughtStoreKind` .iCloud/.local + an observer for iCloud). The
    kind is carried through `AppDependencies` so a later Settings status can read it. Fallback is
    lossless: the local store is never touched and unavailable iCloud is a normal path, not an error.
  - `UbiquitousThoughtObserving` (production `MetadataUbiquitousThoughtObserver`, `NSMetadataQuery` over
    `NSMetadataQueryUbiquitousDocumentsScope`) enumerates iCloud thoughts, triggers downloads for
    not-yet-local items, and fires an `onChange` the Stream list observes to refresh on external
    edits / other-device syncs. Its pure mapping (`UbiquitousThoughtMapping`) is unit-tested with
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
  there is NO utterance-boundary guessing. A finalized result is NOT its own paragraph, though
  (feedback 0012): the `.finalizedSegment` event also carries the raw analysis-relative
  `startSeconds` / `durationSeconds` and an `isAnalysisStart` flag (true for the first finalized result
  of each analysis - set in `beginAnalysis`, cleared after the first finalized emit - so a pause/resume
  seam, where analysis time resets to ~0, forces a paragraph break instead of a bogus negative gap).
  The view model's pure `ParagraphGrouper` groups consecutive segments into paragraphs by the SILENCE
  GAP between them (default 1.5s, a device-tunable constant): a mid-thought breath flows into the
  current paragraph, a real pause breaks. Lightweight `#if DEBUG` emit-timestamp instrumentation and a
  named tap-buffer constant (`tapBufferSize`) leave a device latency pass a measurement hook and a
  tuning lever. The old heuristic
  layer it replaced (`isReset`, `strippingCommittedPrefix`, `committedThisTask`, `resolveEnd`,
  `resolveTaskEndCommit`, task restart) is gone. The mic is tapped so buffers can be teed to the
  recording writer and level meter and converted into the analyzer's format for an
  `AsyncStream<AnalyzerInput>`. Pause finalizes the analyzer so the in-progress utterance commits;
  stop stops emitting and lets the view model fold the last live partial. The record session uses mode
  `.spokenAudio` (Apple's dictation mode - it keeps the input signal conditioning the recognizer needs),
  NOT `.measurement` (which disabled it and degraded transcription, feedback 0026); the transcriber runs
  with EMPTY `transcriptionOptions` for verbatim output (punctuation is NATIVE to `SpeechTranscriber`, and
  its one option `.etiquetteReplacements` REDACTS words, so it is deliberately unset - verified against
  the SDK). The on-device model is
  installed once via `AssetInventory` during authorization (a model download, not audio leaving the
  device). Also holds the Mira control-word pieces: `MiraCommandParser` (pure segment ->
  `MiraParseResult`: `.text`, or `.split(preText:command:)` at the FIRST token matching ANY trigger
  word found anywhere - spec 0018 makes it a `triggerWords: Set<String>` of the primary control word
  PLUS user aliases, lowercased for a case-insensitive, token-boundary match; the `controlWord:` init
  is kept as a one-word convenience),
  `MiraTextProcessor` (the `TextProcessor` that splits at commands), `SentenceTokenizer`
  (`NLTokenizer`-backed, for "remove the last sentence"), `FillerRemovalProcessor` (spec 0016: a pure
  `TextProcessor` that strips standalone hesitation tokens from a conservative default set - only
  unambiguous hesitations, since it is on by default, so no unit/word/interjection is ever removed and a
  filler inside a quoted span is kept - and drops a filler-only segment to `.drop`), `TranscriptCleanup`
  (spec 0016: pure `reflow` that merges obvious continuation lines, plus `refinedForSave(thought, refine:)`
  - the single gate for reflow-on-edit-save), and `Speaker`/`SystemSpeaker`
  (`AVSpeechSynthesizer` text to speech for "read that back"). `SystemSpeaker` sets each utterance's
  voice to the best installed one for the user's language (spec 0014) via the pure `VoiceSelector`
  (`bestVoiceIdentifier(from:languageCode:)`, premium > enhanced > default, exact-region preferred,
  nil -> system default), resolved once from `AVSpeechSynthesisVoice.speechVoices()`.
  - **Dual capture (spec 0007).** The single input tap tees each buffer to THREE sinks: the analyzer
    (converted to its format), the waveform level, and - when recording is armed via
    `setRecordingEnabled(true)` before `start()` - a `RecordingWriter`. The writer is an off-main,
    lock-guarded (`@unchecked Sendable`) helper that appends buffers to a compressed AAC `.m4a`;
    it is created ONCE per session and kept across pause/resume, so one continuous file spans the
    whole thought (finalized only at `stop()`). The tap tees to the writer BEFORE the analyzer so a
    resume offset is not under-counted. `finalizedSegment` events carry a `ParagraphTiming?`: a
    finalized result's audio `CMTimeRange` is relative to the analysis start, so the service adds an
    offset (recording seconds elapsed at analysis start, captured at each resume) via the pure,
    unit-tested `RecordingTiming.absolute` to map a paragraph to an ABSOLUTE range in the one
    continuous recording. `recordingURL()` exposes the temp file for adoption and is documented as
    finalized only after `stop()`;
    `discardRecording()` removes an orphan (even a zero-frame one).
  - **Playback (spec 0007, extended in 0008).** `AudioThoughtPlayer` (production `SystemAudioThoughtPlayer`,
    `AVAudioPlayer`) plays a recording seeked to a range (`play(url:from:duration:)`, a nil duration
    plays to the end; a timer stops a ranged play since `AVAudioPlayer` has no native stop-at),
    mirroring `SystemSpeaker`'s session handling and `onFinish`. Spec 0008 adds `pause()` / `resume()`
    / `currentTime` / `seek(to:)` so the shared controller can pause, resume, publish elapsed, and
    relative-skip. IN-SESSION "read that back" stays on the text-to-speech `Speaker`: the live `.m4a`
    is still open for writing (finalized only at `stop()`), so there is no finalized file to play
    mid-session; both share the `readBackDidFinish` resume handshake.
  - **Dead-air removal (spec 0019) - REMOVED (feedback 0026).** The dead-air trim (`AudioTrimmer` /
    `SilenceTrimmer` / `TimingRemapper`, the `AudioTrimming` seam, the `trimSilence` setting, and the
    trim step in the recording/save path) was removed: the trimmed playback was poor on device and it was
    not worth the complexity. No code path touches recording audio after capture. Two things it once used
    remain because the resume-continues-audio concatenation (feedback 0022) also uses them: the coordinated
    `ThoughtStoring.replaceAudio(from:for:) -> URL?` atomic-swap seam (`ThoughtStore` via `replaceItemAt`;
    `ICloudThoughtStore` via `replaceItemAt` inside an `NSFileCoordinator` `.forReplacing` block, both
    refusing to create a file when the slot is absent), and `Thought.withTimings`.
  - **Resume continues the recording (feedback 0022).** Resuming a thought that ALREADY has audio, with
    audio retention on, now RECORDS a new segment and CONCATENATES it onto the thought's existing `.m4a` so
    the recording continues as ONE file (superseding feedback 0008's "a resumed session records no new
    audio" text-only append). `StreamListView` passes `recordsAudio: audioRetention.recordsAudio` for the
    resume cover regardless of `thought.hasAudio`, plus an `AudioConcatenator` when the thought has audio.
    `AudioConcatenator` (the `AudioConcatenating` seam, AVFoundation, a thin off-main read/write glue)
    reads the existing `.m4a` and the new segment, writes ONE combined AAC file to a PROTECTED temp
    (`completeUnlessOpen`, defer-cleaned on any mid-write failure) via chunked `AVAudioFile` read/write,
    VERIFIES it, and reports the existing recording's measured duration - never touching either input. The
    new paragraphs' timings are timed against the NEW segment's start, so the pure, count-preserving
    `RecordingTiming.offsetResumedTimings` shifts only the new paragraphs (index >= existing count) right by
    that measured duration (pre-existing timings untouched; a zero-length text-only placeholder left in
    place). `DictationViewModel.finish()` returns the FALLBACK thought (original recording kept, new
    paragraphs text-only) and schedules an OFF-main concatenation: concatenate the new segment (joined AS
    CAPTURED - the per-segment dead-air trim was removed in feedback 0026), re-read the thought fresh +
    confirm it still exists, swap through the COORDINATED `replaceAudio`, then re-save the fresh thought
    with the offset timings (only when the paragraph count still aligns 1:1, so a concurrent edit is
    preserved) and reload the feed via the shared `onBackgroundAudioResave` hook. Every failure (empty
    new segment - which must not corrupt the original, incompatible format, verify failure, a delete racing
    the swap) leaves the fallback standing, so the original recording is never lost. A resume onto a
    text-only thought (spec 0013) still adopts a fresh recording, and retention OFF stays a text-only append.
  - **System Now Playing (spec 0008, extended 0027).** `NowPlayingCenter.swift` holds the media-center seam:
    `NowPlayingInfo` (title / duration / elapsed / rate value), `NowPlayingInfoWriting` (production
    `SystemNowPlayingInfoWriter` over `MPNowPlayingInfoCenter`), and `RemoteCommandRegistering`
    (production `SystemRemoteCommandRegistrar` over `MPRemoteCommandCenter`, wiring
    play / pause / toggle / stop / skip-forward / skip-back at a 15s interval, PLUS spec 0027's
    `changePlaybackPositionCommand` - the `scrub:` handler receives the system scrubber's absolute
    `positionTime` and seeks the controller, so the lock screen / Control Center / Dynamic Island scrubber
    drives the same recording the in-app slider does). Both are protocols so the playback controller is
    unit-testable with spies and no real media center. Adding `audio` to `UIBackgroundModes` (Info.plist)
    makes background playback + lock-screen Now Playing work and lights up the Dynamic Island for the
    active audio session; it needs no entitlement (no custom ActivityKit Live Activity).
- `TextProcessor` seam - a finalized segment runs through `process`, which returns a
  `ProcessedSegment`: `.text` to commit, `.split(preText:command:)` (feedback 0006: the dictation
  before the control word plus a command outcome - `.command` to execute or `.unrecognizedCommand` to
  drop with a chip), or `.drop` (a segment to discard with no paragraph - emitted by the filler stage
  when removal empties a segment). `PassthroughTextProcessor` always returns `.text`;
  `MiraTextProcessor` returns `.split` when the parser finds any trigger word anywhere (built with the
  full trigger set - the configured control word plus its aliases, spec 0018); `SpellingOverrideProcessor` is text -> text, applying the user's
  whole-word, case-insensitive overrides via an `NSRegularExpression` word walk (so a substring is
  never corrupted). `CompositeTextProcessor` composes them in the required order: split at the control
  word on the RAW segment FIRST (the command portion must never be spelling-mangled, filler-stripped,
  or transcribed), apply spelling overrides, then (spec 0016, only when `refineTranscript` is on) the
  filler stage, ONLY to the pre-keyword dictation (or the whole segment when no control word is
  present). A whole-segment `.text` that filler removal empties becomes `.drop` (no empty paragraph, and
  the grouper anchor is not advanced - see below); a `.split` whose pre-text empties still runs its
  command with an empty pre-text. The composition root
  (`AppDependencies.makeTextProcessor`) builds one per session, reading the current control phrase,
  its aliases (spec 0018, assembled into the FULL trigger set via `ControlPhrase.triggerWords`),
  overrides, and refine flag off `SettingsStoring` at build time - so edits in Settings apply to the
  next session started, not one in flight.
- `Settings/` - `SettingsStoring` (protocol) and `UserDefaultsSettingsStore` (the local
  `UserDefaults`-backed impl, injected from the composition root) hold the control phrase
  (validated: trimmed, non-empty, sensible max length, else falls back to "Mira"), its
  `controlPhraseAliases` (spec 0018: an ordered `[String]` of extra single-token trigger words,
  validated on read through the shared `ControlPhrase.validatedAliases` seam - each trimmed to one
  token, de-duplicated case-insensitively, never colliding with the primary word; a fresh install
  where the key was never written reads back `ControlPhrase.defaultAliases`, presence-checked like
  `refineTranscript`, and the count is bounded on write), the ordered
  `SpellingOverride` list (persisted as JSON), the `AudioRetention` policy (spec 0007:
  keep / transcript-only / auto-delete after N days, persisted as a small string tag so an unknown
  value falls back to `.keep`), and `refineTranscript` (spec 0016: a `Bool` defaulting to `true` -
  presence-checked on read so a fresh install reads ON, not the `bool(forKey:)` false default - gating
  the filler stage and the edit-save reflow). The `trimSilence` setting (spec 0019 dead-air trim) was
  REMOVED in feedback 0026; its `settings.trimSilence` UserDefaults key is no longer read or written (an
  old stored value is a harmless orphan). Local only - no cloud sync, no per-thought settings.
- `ViewModels/` - `DictationViewModel` (`@MainActor ObservableObject`) is the one place with
  logic: it drives `DictationView` from the speech service, routes finalized segments through the
  `TextProcessor`, executes `MiraCommand`s (thought mutations, new thought save+reset, read-back), and
  saves through the store. Finalized dictation text is grouped into paragraphs by a pure
  `ParagraphGrouper` (feedback 0012) rather than one-paragraph-per-result: the view model calls
  `grouper.decide(...)` with the segment's raw analysis-relative seconds and analysis-start flag and
  either commits a new paragraph or appends to the current one (joined with a space, timings merged so
  the range spans first-start-through-last-end). ORDER MATTERS with the filler stage (spec 0016): the
  view model runs `processor.process` FIRST and only calls `grouper.decide` for a segment that actually
  commits dictation text, so a filler-only segment that the processor reduces to `.drop` neither creates
  a paragraph nor advances the grouper's gap anchor - preserving the feedback-0012 invariant that a
  blank/dropped segment mid-flow cannot shift the boundary the next real segment is measured against. It keeps a `paragraphTimings` array in lockstep with `paragraphs`
  (spec 0007), so every thought mutation (commit, remove-sentence/paragraph, fold-partial) updates
  both, and builds the saved `Thought` with its recording (adopted from the service's temp file into
  the store) and timings at `finish()`. Mid-session "new thought" saves the transcript only - the one
  continuous recording is finalized at Stop and belongs to the FINAL thought. Resuming a thought seeds its
  id, paragraphs, timings, folder, existing recording, and the count of pre-existing paragraphs; the record
  action passes `recordsAudio: audioRetention.recordsAudio` (feedback 0022, no longer gated on
  `!thought.hasAudio`). A text-only thought recorded into (spec 0013) adopts the new audio via
  `saveCurrentThought`'s attach path: the newly spoken tail keeps its real range and the original typed
  paragraphs get zero-length timing placeholders (TTS on playback). A thought that ALREADY has audio KEEPS
  its original recording on save (the safe fallback - the attach path would overwrite it with just the new
  segment) with the new paragraphs zeroed to placeholders, then `finish()` schedules the OFF-main
  concatenation described above that joins the new segment onto the original and re-saves with the new
  paragraphs' offset timings (feedback 0022, superseding the pre-0022 text-only append). In-session read-back
  speaks via the `Speaker` (the live recording is not yet finalized); it pauses capture and resumes
  on `readBackDidFinish`, so the spoken audio never feeds back into recognition. Playback of a SAVED
  thought's recording runs through the shared `ThoughtPlaybackController` and the bottom player (spec 0027,
  which removed the old detail-view `ThoughtPlaybackModel` projection); the detail's "Play recording"
  button just starts the thought on that controller, and it is shown only when `thought.hasAudio`.
  `ThoughtStoreDriver` (headless, `@MainActor`, no SwiftUI) owns
  the thoughts list: it loads through the store on a detached task (the iCloud store's `loadAll()` can
  block on coordinated IO, so it must not run on the main actor) and, on iCloud, wires the
  `UbiquitousThoughtObserving` observer once (`start`/`stop`, `onChange` -> reload) so the list
  refreshes on synced-in / external edits without restarting the query on navigation. The load and
  observe logic lives in the driver so any consumer can run it - the CarPlay browser as well as
  SwiftUI. `StreamFeed` (`@MainActor ObservableObject`) is a thin projection over the driver,
  republishing its `thoughts`/`didLoad` so a view can bind. `ThoughtStoring: Sendable`, so the detached
  load is sound under strict concurrency.
  - **Folder navigation model (spec 0010, PR B).** The driver/feed also expose the folder seams -
    `childFolders(at:)`, `createFolder`/`renameFolder`/`deleteFolder`, and `move(_:to:)` (a re-save with
    a new `folderPath`) - each on a detached task then a reload, so the whole thoughts list stays the one
    source. The list PROJECTION is pure and testable in `FolderListModel` (`@MainActor`): it takes the
    driver's flat `thoughts`, the child folder names the store reported at a path, the current path, and the
    chosen `ThoughtSortOrder`, and returns an ordered `[FolderListItem]` (`.folder(name:path:)` or
    `.thought`). Thoughts are filtered to those whose `folderPath` EQUALS the current path; each folder gets a
    `SortKey` whose date is its newest descendant thought (recursively, `.distantPast` when empty) and whose
    title is its name, so folders and thoughts interleave through the SAME `ThoughtSortOrder.areInIncreasingOrder`
    comparator - no second copy of the ordering. `FolderMoveTargets` is a second pure builder: driven by a
    `children` closure (`store.folders(at:)`), it flattens the tree pre-order with depth for the
    move-to-folder picker, so an empty folder (never in any thought's `folderPath`) is still offered.
  - **Folder model redesign - top-level folders + aliases (spec 0026).** The top level is FOLDERS ONLY, one
    level deep, so `FolderListModel`'s interleaved folders-and-thoughts projection is REPLACED for the
    top-level and folder screens by the pure, UI-free `TopLevelFolders` (`FolderListModel` and its tests are
    deleted - no code referenced them after the redesign). `TopLevelFolders` holds the alias projections
    `allThoughts(_:sorted:)` (every thought flat, honoring sort) and `recents(_:limit:)` (the 10 most recent
    by `createdAt`, newest first, independent of the chosen sort, reusing the `.newest` total comparator so
    ties are deterministic; `limit 0` -> none, negative -> uncapped), plus `folderThoughts(_:folder:sorted:)`
    - a user folder's thoughts FLATTENED over any legacy nested subtree via the ONE `belongs(_:toFolder:)`
    membership rule (a thought whose `folderPath.first` equals the folder name - component equality, so
    "Work" does not swallow "Workshop" - shared by the list and the count so they cannot drift) -
    `uncategorized(_:sorted:)` (thoughts with an empty `folderPath`), `thoughts(_:for:sorted:)` (the
    subject-driven projection the views render), `folderThoughtCounts(_:)` (all folders' counts in one pass,
    so a top-level list does not rescan per row), and the count/label/name helpers. The two virtual aliases
    are the `AliasFolder` enum (`.allThoughts`, `.recents`); they are pure projections, never real dirs, and
    cannot be renamed/deleted. `FolderSubject` (`.userFolder`/`.alias`) is the pure "what a flat screen shows"
    type both the projection and the placement key off. `NewThoughtPlacement.folderPath(for:)` /
    `(browsingFolder:)` is the pure placement decision: inside a user folder -> that folder, from the top
    level / an alias -> uncategorized (`[]`). `SplitDetailReconcile.contentSubjectSurvives(_:inFolderNames:)`
    reverts the split content column to its placeholder when the shown user folder is renamed/deleted from the
    sidebar (an alias always survives). Storage is unchanged; `createFolder` and move-to-folder target the top
    level only, and deeper legacy dirs keep loading (their thoughts surface flattened). The seams are
    unit-tested (`TopLevelFoldersTests`, `NewThoughtPlacementTests`, `SplitDetailReconcileTests`).
  - **Shared playback + CarPlay browser (spec 0008, extended 0027).** `ThoughtPlaybackController` (`@MainActor
    ObservableObject`) is the ONE audio path: it owns an `AudioThoughtPlayer`, an `AudioURLResolving`
    (lazy off-main resolution at play time, as 0007's model did; the `AudioURLResolving` protocol +
    `StoreAudioURLResolver` now live in their own `ViewModels/AudioURLResolving.swift` after spec 0027
    removed the `ThoughtPlaybackModel` they used to share a file with), and the Now Playing / remote-command
    seams, exposing play / pause / resume / stop / skip and one writer of `MPNowPlayingInfoCenter`.
    **Transport (spec 0027):** it also publishes `elapsed` / `duration` and owns a live-progress ticker (a
    ~250ms `Task` loop that samples `player.currentTime` into `elapsed` and refreshes Now Playing while
    playing, started on play/resume and cancelled on pause/stop/finish), plus `seek(to:)` (absolute,
    clamped to `[0, duration]` via the pure `PlaybackProgress.clamp`) that the in-app slider drag AND the
    system scrubber both drive; `skip(by:)` routes through `seek` so it clamps too. The phone detail view
    no longer hosts an in-note transport (spec 0027 removed `ThoughtPlaybackModel`): its "Play recording"
    button just starts the thought on the controller, surfacing the bottom player - which the detail page now
    ALSO anchors in its own bottom safe-area inset (feedback 0027, see `ThoughtDetailView` below), so the same
    transport works while a thought is open, not only on the list screens. The CarPlay scene drives
    the same controller. **Scrubber stall fix (feedback 0027):** the bottom player's slider display is gated by
    an explicit `isScrubbing` drag flag through the pure `PlaybackProgress.scrubDisplay` (shows the held scrub
    value only WHILE dragging, else the live `elapsed`), so a stray post-release `Slider` binding write cannot
    permanently mask progress and freeze the bar at the drop point. **Queue (spec 0015):** the
    controller also owns an internal ordered `queue: [Thought]` + index. `playQueue(_:)` filters to
    `hasAudio` thoughts and plays the first through the shared start path; the NATURAL end-of-track path
    (`handleFinish`) advances to the next until the queue is exhausted, then clears. The advance is
    distinguished from a user stop by the same `suppressFinish` flag the single-play teardown uses - a
    user `stop()` sets `suppressFinish` (via `clearPlayback`) and clears the queue, so `handleFinish`
    returns early and never advances; only a real end reaches the advance. A direct `play(thought:)` (a
    thought swipe, the detail button) clears any prior queue so an orphaned queue never resumes. Published
    `currentThought` / `hasNext` (and `currentTitle`) drive the now-playing bar. `RecordingsListModel`
    (`@MainActor`, callback-observable like the driver, not SwiftUI - the CarPlay delegate is UIKit)
    projects `ThoughtStoreDriver.thoughts` to only thoughts with a recording, newest first, each with a
    formatted duration (`recordingDuration` = the tail of the last-ending timing range), and refreshes
    on driver change; its duration formatting is a pure, unit-tested static.
  - **Undoable delete (spec 0020).** The driver/feed route delete through the store's soft-delete:
    `delete(id:)` calls `softDelete` and RETURNS the `DeletedThought` token (nil on failure/nothing),
    `restore(_:)` and `purge(_:)` undo/commit it, and `purgeAllTrash()` is the launch sweep - each on a
    detached task then a reload, like the other store ops. `ThoughtDeletionController` (`@MainActor
    ObservableObject`, owned by `StreamListView`) is the ONE undoable-delete coordinator: every delete
    entry point (list swipe, list-row context menu, thought-detail "..." menu) calls it, so the delete is
    soft, registered with the scene's `UndoManager` (undo -> restore, redo -> re-delete, action named
    "Delete" so the system prompt reads "Undo Delete"), and shown with the in-app "Thought deleted - Undo"
    affordance. It holds the pending token and a monotonic `deleteTrigger`; the affordance's ~5s window
    is lifecycle-tied (a `.task(id:)` on the trigger, same shape as the copied-confirmation chip - no
    detached timer), and on expiry it `purge`s (commits the delete). The controller takes the scene
    `UndoManager` from SwiftUI's `@Environment(\.undoManager)`; `applicationSupportsShakeToEdit` stays
    at its default so the shake surfaces the registered action.
- `Views/` - SwiftUI screens. `StreamListView` is the ROOT of the Thoughts navigation, an ADAPTIVE
  container (spec 0022): the pure `StreamContainer.decide(horizontalSizeClass:)` chooses a
  `NavigationSplitView` on REGULAR width (iPad, iPhone landscape where it fits) or the single
  `NavigationStack` on COMPACT (iPhone portrait). Both share the SAME enum route
  `StreamRoute { case folder([String]); case thought(Thought); case newThought(Thought) }`, the same
  shared session/settings/playback wiring + sort-order state, the same dictation / resume covers and
  Settings sheet (lifted above the container so neither forks them), and the same `detailView(for:)`
  builder (so the compact destination and the split detail column construct the thought detail once).
  The COMPACT `compactStack` is the pre-0022 body verbatim (one `FolderContentsView` at a time, each with
  its own bottom bar). The SPLIT `splitView` puts the root folder tree in the SIDEBAR, the sidebar-selected
  folder's thoughts in the CONTENT column (its own `NavigationStack` so nested folders push there), and the
  `selectedRoute` thought in the DETAIL column (a `SplitDetailPlaceholder` when none). Under the split view
  the bottom bar + search + now-playing + undo chip are LIFTED to ONE `liftedBottomStack` above the columns
  (the 0021-review requirement): both folder columns own no bar and share the ONE
  `StreamSearchProjection.resolve(...)` computed once at the container (a pure, SwiftUI-FREE seam factored
  out of `FolderContentsView.resolveContent`, so the two columns do not each re-scan the shared query - and
  reusable by a future Watch target). Whether a folder screen owns its own bottom bar is the tested
  `StreamContainer.folderScreenShowsOwnBottomBar` decision (compact: true, split: false) driving the call
  sites, not a raw literal, so the single-bottom-bar invariant cannot silently regress. The lifted bar AND
  the compact per-screen bar are the SAME extracted `StreamBottomStack` view (one place for the composition
  + the 5s undo-window timer, de-duped and reusable). Four split-only correctness rules the panel review
  added: (1) during an active search the SIDEBAR keeps its normal folder tree
  (`StreamSearchProjection.sidebarProjection` demotes an active-search state to `.normal`), so exactly ONE
  global results list shows - in the content column, not double-rendered beside the sidebar; (2) the DETAIL
  selection is reconciled so it never goes stale - `selectSidebarFolder` clears `selectedRoute` on a folder
  switch, and a delete clears it when the deleted id is the shown thought (the pure `SplitDetailReconcile`);
  (3) the lifted projection gates on `feed.didLoad && splitFoldersLoaded` (matching the compact
  `feed.didLoad && folderLoaded` gate, via `FolderContentsView.onFoldersLoaded`) so the split view does not
  flash the empty CTA mid-load; (4) the split detail column drops its own search field (defers to the
  always-visible lifted bar). The `UndoManagerHost` gains a `reclaimTrigger` the root bumps on a split-column
  change (sidebar folder / detail thought selection) so it re-homes first responder and Shake to Undo keeps
  reaching the deletion controller's manager regardless of active column, PLUS a self-heal on a layout pass
  (rotate / resize / multitasking, which fire no selection change) and on the orientation notification, gated
  on a pending delete. It renders
  `FolderContentsView(path: [])` as the root with a `navigationDestination` for the routes.
  `FolderContentsView` renders the same folder-list screen at ANY path (so a pushed `.folder` recurses
  into another instance), projecting its rows through `FolderListModel`; it owns the folder-CRUD alerts,
  the sort menu, swipe/context actions, the `MoveToFolderSheet`, and the empty states. **Swipe to play
  (spec 0015):** a leading swipe adds a Play action - `controller.play(thought:)` on a recorded thought row
  (no Play on a text-only thought), and `controller.playQueue(...)` on a folder row, built from the feed's
  thoughts filtered to that folder's subtree (`FolderListModel.isDescendant`) with a recording, ordered by
  the current `ThoughtSortOrder`. **Persistent bottom bar + search (spec 0021):** the shared `BottomBar`
  (a Canopy capsule: a wide search field on the left, an icon-only trailing action slot the caller
  fills - `BottomBarIconButton`/`BottomBarRecordButton` for new-thought + record, dropping text labels but
  keeping accessibility labels) lives in the bottom safe-area inset. `FolderContentsView` renders one of
  four states chosen by the PURE `FolderScreenState.select(...)`: `.emptyStore` (a centered
  `FolderEmptyStateCTA` with the LABELED record + new-thought buttons, and no bottom bar - the CTA carries
  the actions), `.searchResults` (a flat GLOBAL result list from `ThoughtSearch.results` over `feed.thoughts`,
  ignoring `folderPath`), `.noMatches` (a message, search field kept visible), or `.normal` (the
  interleaved `FolderListModel` list). The `searchQuery` is a `@Binding` owned by `StreamListView` (so a
  search started on the thought page can pop to root and land here). The bottom PLAYER (`BottomPlayer`,
  spec 0027, superseding spec 0015's `NowPlayingBar`) still sits above the bottom bar in the same inset -
  now a full transport (title, play/pause, draggable seek slider with elapsed/remaining labels, skip
  +/-15s, Next while a queue has one), rendered in the ONE `StreamBottomStack` so compact and the iPad
  lifted stack share it. The transient undo-delete chip (spec 0020) now renders at the
  TOP of that same VStack (its ~5s window timer moved here, lifecycle-tied and keyed on
  `ThoughtDeletionController.deleteTrigger`, replacing the old root overlay + hardcoded clearance), so the
  three bottom affordances compose without overlap. `ThoughtDetailView`'s bottom bar reuses the SAME
  `BottomBar` with a resume icon (shown only when `resumeApplies` per the audio-retention setting,
  computed at the root); its search field routes to the global results on SUBMIT (via `onSearch`, which
  pops to root and sets the shared query) rather than per keystroke. The detail page's bottom inset ALSO
  hosts the shared `BottomPlayer` above its own bar (feedback 0027, `detailBottomStack`), gated on the SINGLE
  container decision `StreamContainer.detailHostsBottomPlayer` (the same seam shape as
  `folderScreenShowsOwnBottomBar`, derived once in `StreamListView.detailView`) - TRUE on the compact stack
  (the pushed detail owns its own inset, so the player is repeated there and the transport works on the thought
  page) and FALSE in the iPad split view (the player is lifted above all columns, so hosting it in the detail
  column too would double-render it). A tap on the player's title routes through the detail's `onOpenThought`
  (the same container-aware `openThought` the list uses). **Folder dialogs (feedback 0018):**
  the New folder / Rename / Delete alerts were three STACKED `.alert`s on one node (a SwiftUI flakiness
  source that broke rename); they are now ONE `FolderDialog` enum (`@State activeDialog`) with each alert
  on its OWN hidden `Color.clear` background anchor via a per-case binding, and the name text in a
  separate `@State` so editing it does not churn the enum identity. **Contextual record (feedback
  0018):** the record/new-thought action carries the current folder path (`onNewThought([String])`), the
  root captures it at tap time (`newThoughtFolderPath`) and passes it to `DictationViewModel(folderPath:)`
  so a thought recorded inside a folder is filed there, not at the root; the thought page passes its thought's
  `folderPath`, and hands-free entry points pass `[]`. Both the root and folder titles use a large title
  below the toolbar (feedback 0018, superseding feedback 0016's inline title). `FolderRow` mirrors
  `ThoughtCard`'s surface with a folder glyph, item count, and chevron. `UndoManagerHost` (a
  `UIViewControllerRepresentable` embedding a zero-size first-responder `UIViewController` that vends a
  STABLE `UndoManager`) is overlaid at the root and its manager injected into `ThoughtDeletionController`,
  so Shake to Undo works (feedback 0018) - `@Environment(\.undoManager)` is frequently nil in plain
  SwiftUI, so the delete had nothing registered for the shake to reach. The host RE-CLAIMS first
  responder on keyboard-hide / text end-editing / app-active (not just on appear), because the
  now-omnipresent search field steals first responder and would otherwise break the shake after the first
  text focus. The thought-detail bottom bar's "search / resume / hidden-while-editing" choice is the pure,
  tested `ThoughtDetailBottomBar.decide(...)` (hidden entirely while editing so the search field never
  renders under the keyboard and a new thought does not show two competing fields); the folder screen
  computes its search results ONCE per render (a single `resolveContent()` feeds both the state selection
  and the results list, scanning only when a search is active) instead of rescanning per keystroke.
  `DictationView` binds to `DictationViewModel`; `ThoughtCard`,
  `ThoughtDetailView` stay presentational. On a committed edit, `StreamListView`'s `onCommitEdit` runs
  the thought through the pure `TranscriptCleanup.refinedForSave(thought, refine: settingsStore.refineTranscript)`
  before saving (spec 0016): when the flag is on it reflows continuation lines, rebuilding via
  `Thought.editedCopy` so the title, recording, timings, and folder are preserved, and returns the thought
  unchanged when off or when nothing merges. That pure gate is the SINGLE enforcement of "reflow on
  edit-save when refine is on, never on load" - no load path calls it, so an untouched loaded thought is
  never silently rewritten (unit-tested off/on/no-op).
  - **Folder model redesign (spec 0026).** The interleaving `FolderContentsView` is RETIRED and replaced by
    two screens over the pure `TopLevelFolders`: `TopLevelFoldersView` (the FOLDERS-ONLY top level - the two
    `AliasFolder` rows then the user folders, owning the new-folder / rename / delete dialogs and the
    top-level sort menu) and `FolderThoughtsView` (a FLAT thought list for a user folder or an alias). The
    `StreamRoute` enum gains `.alias(AliasFolder)` and `.folder([String])` is now a one-level user folder;
    the compact stack roots at `TopLevelFoldersView` and pushes `FolderThoughtsView` for a `.folder`/`.alias`,
    and the split view puts `TopLevelFoldersView` in the sidebar and the selected subject's `FolderThoughtsView`
    in the content column (a `FolderThoughtsView.Subject` = user folder or alias). The screen TITLE is now the
    FIRST scrollable list row (`StreamListTitleRow`, same Canopy H3 size + bold as the old fixed title) and
    scrolls away, superseding feedback 0016/0020/0024's fixed below-the-toolbar `.streamListTitle` (retained
    but no longer applied to these screens). Rows use the tighter `tightRowInsets()` (vertical inset dropped
    from `x1_5` to `x0_5`) for a dense list, keeping the card's own padding for tap targets. The feedback-0024
    search-field-focus fix is preserved (the bottom `StreamBottomStack` hangs off the STABLE outer node; only
    the content switches on state - now WITHIN one persistent `List`, feedback 0029, see below). Shared chrome
    (`ThoughtResultRow`, `FolderDialog`, `FolderEmptyStateCTA`, `FolderErrorBanner`, `NoMatchesRow`,
    `EmptyUserFolderCTARow`, `unifiedRow`, `unifiedList`) lives in `FolderScreenChrome`. `NoMatchesRow` and
    `EmptyUserFolderCTARow` are the no-matches message and the empty-user-folder CTA rendered as ROWS inside
    the single persistent `unifiedContentList`, not separate centered views, so the search field's host is
    never torn down mid-typing (feedback 0029, item 8 - the earlier `NoSearchMatchesState` centered view is
    retired). `ThoughtResultRow`
    is the ONE thought row both the flat folder list AND the global search-result list render (on either
    screen), so a thought's affordances (leading Play/Move swipe when it has audio, trailing Delete, the
    Share/Copy/Move/Delete context menu) are identical everywhere - a search result cannot gain/lose
    swipe-to-play based on which screen the search started from, and it is the single wiring point a future
    "play -> bottom player from a row" hooks into. Global search stays the same
    `StreamSearchProjection`/`FolderScreenState` seam (it reaches every thought, folder or uncategorized).
  - **List / folder UX fixes (feedback 0026).** Six polish fixes on the spec 0026 screens. (1) Tighter list
    headers: `StreamListTitleRow` insets drop to `x1`/`x1` and `unifiedList()` overrides the `.insetGrouped`
    top content margin to `x2`, so the scrolling title sits close to the rows and toolbar (Notes-app). (2)
    Row-icon alignment: `FolderRow`'s glyph gains a fixed `.frame(width: x8)` matching the alias tile, so every
    row label lines up on one left edge. (3) Search focus: a stable `.id("stream-bottom-stack")` on the
    `StreamBottomStack` in the bottom safe-area inset keeps the search `TextField` the SAME instance across the
    normal->results->no-matches content flip, so focus survives the first keystroke and the no-matches state
    (the `FolderScreenState.showsSearchField` seam already kept the field mounted). (4) Folder rename/delete:
    the alert button captures the dialog's target path SYNCHRONOUSLY through the pure, unit-tested
    `FolderDialogAction.capture(from:name:)` seam before its async `Task`, because the dialog's dismissal
    binding clears `activeDialog` before a deferred read would run (the store/driver/feed were already correct
    - see learnings; the seam lets a regression test cover the real path). (5) In-folder menu:
    `FolderThoughtsView` gains a nav-bar "..." menu (user folders only, not aliases) with Rename / Delete
    folder, routed through the SAME `FolderDialogAction.capture` seam to new `onRenameFolder`/`onDeleteFolder`
    callbacks the root implements - rename re-points navigation at the new name, delete pops back (compact) or
    clears the split selection. (6) Empty-state third action: `FolderEmptyStateCTA` takes an optional
    `onMoveToFolder`; inside an empty USER folder (store non-empty) the normal state renders the CTA with Move
    thoughts here / Record / New, and `MoveThoughtsIntoFolderSheet` (a new multi-select picker over every
    thought not already in the folder) re-files the chosen thoughts via a new BATCH `feed.move(_ thoughts:to:)`
    (one reload, no per-thought flicker). The Move action is omitted in the root / All Thoughts / an alias / a
    truly empty store.
  - **List / folder screen fixes (feedback 0029).** Five follow-ups on the same screens. (2) The sort
    `ToolbarItem` is removed from `TopLevelFoldersView` (folders-only top level has nothing thought-ordered to
    sort); `sortOrder` stays a binding, still ordering `FolderThoughtsView` and the top-level swipe-to-play
    queues, so no state is orphaned. (3) `MoveThoughtsIntoFolderSheet` gains a `.searchable` field filtering
    candidates through the shared `ThoughtSearch.results` matcher; selections are a `Set<UUID>` stable across
    filtering. (4) "Move thoughts here" is reachable on a NON-empty folder too: `FolderThoughtsView`'s "..."
    menu and each `TopLevelFoldersView` folder row's swipe + context menu (beside Rename), all opening the ONE
    `MoveThoughtsIntoFolderSheet` + BATCH `feed.move(_ thoughts:to:)`. (7) `StreamListTitleRow` bottom inset
    drops to `x0` and `unifiedList()`'s top content margin to `x1`, so the first row sits closer under the
    title. (8) Search-focus, ROOT-CAUSE fix (third recurrence): the earlier stable-`.id` on the bottom stack
    was insufficient because the `.safeAreaInset` hosting the search `TextField` was attached to a content node
    that SWAPPED one `List` view for a structurally different one on the query-driven state flip - SwiftUI tore
    down the hosting subtree and resigned first responder. `switchingContent` now renders ONE persistent
    `List` (`unifiedContentList`) for the normal / results / no-matches states, varying only its ROWS
    (`NoMatchesRow` and, in a folder, `EmptyUserFolderCTARow` are rows inside it), so the field's host identity
    is constant; only `.emptyStore` renders outside the list, and it has no field. The pure
    `FolderScreenState.contentUsesList` seam pins which states share the list (unit-tested); the one-List
    STRUCTURE and live first-responder retention are device-verified.
  `SettingsView` edits the injected
  `SettingsStoring` instance directly (control-phrase field with validation hint, a command-aliases
  editable list below it - spec 0018: an add field + plus button gated by the same
  `ControlPhrase.validatedAlias` rule the store uses, so an empty/multi-word/duplicate/primary-colliding
  entry cannot be added, plus swipe-to-delete rows - a "Refine transcript"
  toggle, add/edit/delete override rows, a read-only storage-status row from `ThoughtStoreKind`). The chosen `ThoughtSortOrder` persists through
  `SettingsStoring.thoughtSortOrder` (a stable string tag; unknown -> `.newest`).
- `DesignSystem/` - vendored `Tokens.swift` from Canopy and a small `RelativeTime` helper. `Tokens.swift`
  stays PRISTINE-generated except for ONE loud two-line marker (spec 0023): its `Color(light:dark:)` /
  `Color(rgb:)` extension is wrapped `#if !os(watchOS)`, because that extension uses
  `UIColor(dynamicProvider:)` which is `API_UNAVAILABLE(watchos)`. The actual watch implementation lives in
  a HAND-OWNED `ThoughtStreamShared/CanopyColorWatch.swift` (`#if os(watchOS)`, resolves each color to its
  dark value), so a Canopy re-sync that overwrites `Tokens.swift` only needs the two-line wrapper re-added
  (the file header says so), not a logic port. The generated `CanopyColor` enum still holds the token
  VALUES on both platforms.
- `Assets.xcassets/` - single 1024 universal `AppIcon`.
- `Watch/` (spec 0023) - the PHONE side of the Apple Watch link. `PhoneConnectivityCoordinator` owns the
  `WCSession`: it receives a transferred `.m4a` capture, ingests it (SERIALIZED through an `IngestQueue`
  actor so a reconnect batch never runs concurrent `SpeechAnalyzer` passes), and pushes the recent-thoughts
  projection back - the push is DEBOUNCED and runs OFF the delegate thread (a `store.loadAll()` behind a
  background task), so a synced-in batch or a multi-delete coalesces into one load + one context write
  rather than N. It also answers an on-demand audio request with a tagged `transferFile`. Ingest is a pure
  core plus a thin IO shell: `SpeechAnalyzerFileTranscriber` (the `FileTranscribing` seam) runs
  `SpeechAnalyzer.analyzeSequence(from:)` over the file and decodes each finalized result into
  `[TranscribedSegment]`; the pure `FileTranscriptionMapper` maps those to paragraphs + timings REUSING
  `ParagraphGrouper` (silence-gap grouping, offset 0 since a file has one timeline) and
  `ParagraphTiming.merged`; the pure `WatchCaptureIngestor` builds the `Thought` (title, folder-hint
  resolution against existing folders, and the audio-only fallback that NEVER drops a capture, with a
  positive-duration guard so a degenerate timing never claims a non-playable recording); and
  `WatchCaptureIngestService` ties transcribe -> build -> save -> save-audio -> single final save through
  the existing `ThoughtStoring`. IDEMPOTENCY: `ingest` SKIPS the whole flow (no re-transcribe, no re-save)
  when a thought with the capture id already exists, so a WatchConnectivity RE-DELIVERY is a no-op and never
  clobbers a phone edit made between deliveries (the capture id is the thought id). The coordinator is built
  and activated in `AppDependencies.resolve` (nil in tests / on an iPad with no watch), its
  `recentThoughtsProvider`/`audioURLProvider` capturing the store; `StreamFeed.onThoughtsChanged` calls the
  debounced `pushRecentThoughts` on every list change so the wrist stays fresh. A no-op where
  WatchConnectivity is unavailable, so the iOS-only path is unchanged.

## Shared source (`ios/ThoughtStreamShared/`) and the watch target

- `ThoughtStreamShared/` (spec 0023) - platform-neutral source compiled into BOTH the iOS app and the
  watchOS app, so the two sides share ONE definition and cannot drift. Holds `WatchConnectivityPayload`
  (the `WatchCaptureMetadata` and `RecentThoughtProjection` value types plus the pure `WatchConnectivityCodec`
  that encodes/decodes them to the plist-safe `[String: Any]` dictionaries a `WCSession` moves - no
  WatchConnectivity import, so the wire contract is unit-testable). Every payload carries a `kind` marker
  (`capture` / `recentThoughts` / `audioRequest` / `audioResponse`) so a receiver routes STRUCTURALLY, not
  by guessing which fields are present, and ALL wire field names are centralized in the codec so the two
  sides cannot drift on a raw literal (the audio request/response keys were previously hand-typed at each
  call site). Also `RecentThoughtsProjector` (pure `[Thought]` -> capped `[RecentThoughtProjection]`) and
  `CanopyColorWatch` (the hand-owned watchOS `Color(light:dark:)`/`Color(rgb:)` glue, `#if os(watchOS)`,
  kept out of the generated `Tokens.swift`).
- `ThoughtStreamWatch Watch App/` (spec 0023) - the watchOS app. `ThoughtStreamWatchApp` roots a two-tab
  `TabView` (Capture / Recent). `WatchRecorder` records the mic to `.m4a` (`AVAudioRecorder`) with a
  start/stop haptic; `WatchConnectivityManager` (the watch `WCSession`) `transferFile`s a capture reliably,
  receives the recent-thoughts application context (published for the list), and requests/receives audio on
  demand. `WatchCaptureView` is the Record control; `WatchBrowseView`/`WatchThoughtRow` list the projection;
  `WatchThoughtDetailView` shows a thought's text and plays its audio via `WatchAudioPlayer` (`AVAudioPlayer`).
  The watch target also compiles the specific platform-neutral iOS files it reuses (`Thought`,
  `RecordingTiming`, `ParagraphGrouper`, `SentenceTokenizer`, `Tokens`) rather than forking them.
- **XcodeGen targets (spec 0023):** `ThoughtStreamWatch` is a watchOS `application` (deployment target 26.0),
  companion bundle id `com.rogueoak.thoughtstream.watchkitapp`, embedded in the iOS app via a `dependencies:
  embed: true` entry; the iOS app and the watch app both list `ThoughtStreamShared` in their sources. A
  `ThoughtStreamWatch` scheme builds/runs it on a paired watch simulator. Code signing is disabled for the
  `watchsimulator` SDK (like the iphonesimulator config), so the unsigned build stays green.

Tests live in `ios/ThoughtStreamTests/` (a `bundle.unit-test` target): `ThoughtStore`, `Thought`
Markdown, `DictationViewModel` save/reload, the `MiraCommandParser` grammar, `SentenceTokenizer`,
Mira command execution (thought mutations, new thought, read-back via a `Speaker` stub, and
`TextProcessor` result routing via stub capture/speaker doubles), the `ICloudThoughtStore` coordinated
round-trip against a temp dir (plus cross-store file compatibility and the bare-markdown fallback
path), `ThoughtStoreFactory` selection and lossless fallback via a stub `UbiquityContainerProviding`,
the `UbiquitousThoughtMapping` metadata-to-thoughts logic via stub items, and the driver's load +
observer wiring (start/stop, onChange -> reload, local no-observer path, no-reload-after-stop) via
stub store/observer through the `StreamFeed` projection, and the hands-free session-start seam (the
`PendingSessionRoute` request/consume lifecycle, both App Intents requesting a start through a stub
`SessionStarter`, `openAppWhenRun`, and the App Shortcuts being registered), plus Settings:
`UserDefaultsSettingsStore` persistence and control-phrase validation via an isolated defaults
suite, the command-word aliases (spec 0018: parser matches any trigger word / case-insensitive /
token-boundary so "admiral" != "mira" / removed alias stops firing; store default-set-on-fresh-install,
round-trip, empty-persists, and rejection of empty/multi-word/duplicate/primary-collision, plus the
factory building the parser from the full alias set),
`SpellingOverrideProcessor` whole-word/case/multi-override/no-substring-corruption, and
`CompositeTextProcessor` ordering (a command is detected and not spelling-mangled; the configured
control word changes matching; a normal segment gets overrides), plus the CarPlay Audio surface
(spec 0008): the shared `ThoughtPlaybackController` (play / pause / resume / stop / skip via a stubbed
player, `MPNowPlayingInfoCenter` populated via a spy, remote-command handlers calling back into the
controller via a spy), the `RecordingsListModel` (audio-only filter, newest-first order, duration
formatting, and driver-change -> list refresh via a stub store + observer), and the CarPlay Start row
routing through the shared `SessionStarter`, plus the folder UI models (spec 0010, PR B):
`FolderListModel` (filter-by-path, folder/thought interleave for each sort order, folder date = newest
descendant recursively, empty-folder-to-the-end), `FolderMoveTargets` (pre-order + depth flatten,
empty folder still offered, sibling A-Z, subtree exclusion), and `thoughtSortOrder` persistence /
unknown-tag fallback in `UserDefaultsSettingsStore`, plus the recoverable delete (spec 0020): both
stores' `softDelete`/`restore`/`purge`/`purgeAllTrash` (audio sibling moved + restored, restore to
root when the original folder is gone, trash stays inside the store root, purge is permanent), and
the same seam driven through `StreamFeed`/`ThoughtStoreDriver` (delete returns a restorable token,
restore re-inserts the thought and audio, purge removes it). The system `UndoManager`/shake gesture is
verified manually, not in tests. Plus the full-text search + bottom-bar redesign (spec 0021):
`ThoughtSearch` (title match, body-paragraph match, substring, case- and diacritic-insensitivity, no-match,
empty/whitespace query returns all, GLOBAL multi-folder results in preserved order) and `FolderScreenState`
(empty-store-regardless-of-search, normal, results, no-matches selection, plus search-field visibility).
The bottom-bar/now-playing/undo composition, the live search field, and the empty-state CTA are UI-only and
verified on device. Plus the in-thought find (spec 0025): `ThoughtFindTests` cover `ThoughtFind` (title
match, body-paragraph match, ordering title-then-paragraphs-then-left-to-right, case/diacritic
insensitivity with the highlighted range covering the ORIGINAL accented text, substring, no-match, empty/
whitespace query, outer-whitespace trim) and `ThoughtFindNavigator` (starts on the first match, next/
previous walk + WRAP, "N of M" count, empty-list no-current/empty-count/no-op nav, and the region ->
scroll-anchor id mapping). The AttributedString highlight rendering and the scroll-into-view are UI-only
and verified on device. Plus the feedback-0018 fixes:
`FolderRenameDriverTests` (rename through `StreamFeed` renames on disk, moves thoughts, returns the name,
republishes; conflict + invalid-name rejection), the injected-UndoManager registration
(`ThoughtDeletionControllerTests` - a delete registers "Undo Delete" on the injected manager; the shake
gesture and the undo-through-the-manager restore stay manual-verify), and contextual folder filing
(`DictationViewModelTests` - a session created from path `[X]` files its thought in `[X]`; the default
files at the root). Plus the iPad adaptive layout (spec 0022): `AdaptiveLayoutTests` cover
`StreamContainer.decide` (regular -> split, compact -> stack, nil -> stack), the bar-ownership mapping
(`folderScreenShowsOwnBottomBar` - compact true, split false, locking the single-bottom-bar invariant),
`StreamSearchProjection` (the lifted, one-scan search projection: not-loaded -> normal/no-results,
empty-store, normal, global active-query matches in preserved order, no-matches, and parity with
`FolderScreenState.select`), the sidebar demotion (`sidebarProjection` demotes active-search states to
`.normal` so only ONE results list shows), and the detail reconcile (`SplitDetailReconcile` clears the
selection when the shown thought is deleted, keeps it otherwise, clears nothing when none shown). The
split-view column LAYOUT, the one-projection sharing across columns (wiring, not unit-proven),
rotation/multitasking adaptivity, and the cross-column Shake-to-Undo re-home + layout-pass self-heal are
UI-only and verified on device / in the iPad simulator. Plus the Apple Watch link (spec 0023): the pure
wire codecs (`WatchConnectivityCodecTests` - capture-metadata, recent-thoughts, and audio-request/response
encode/decode round-trip; tolerant decode of missing/wrong-kind/malformed rows; every payload carries its
`kind` marker; request and response are NOT confused structurally despite both carrying a thought id), the
file-transcription mapping (`FileTranscriptionMapperTests` - segments -> paragraphs+timings, silence-gap
flow vs. break with CONCRETE merged/broken timing values, whitespace skip, degenerate-range placeholder,
1:1 alignment), the recent-thoughts projection (`RecentThoughtsProjectorTests` - title/preview/duration/
audio-flag, preview flatten+cap, limit, order), the pure ingest decisions (`WatchCaptureIngestorTests` -
transcribed thought, audio-only fallback that never drops a capture, unusable-duration -> text-only for
both the audio-only and transcribed paths, folder-hint resolve/fallback), and the ingest service end to end
(`WatchCaptureIngestServiceTests` - a stub transcriber + real `ThoughtStore` in a temp dir proving the
transcribed and audio-only-fallback paths file a thought with audio, folder-hint filing, a HOSTILE hint
(`..`/absolute/control-char/separator) landing at top level, and IDEMPOTENCY: a re-delivered capture yields
ONE thought and does not re-transcribe, and a phone edit made between deliveries is preserved). The watch
UI, real on-watch mic capture, the live WatchConnectivity transfer, and real file transcription are
device/simulator-verified. Plus resume-continues-audio (feedback 0022): the pure offset math
(`RecordingWriterTests` - new paragraphs shifted past the existing duration, pre-existing timings
unchanged, zero-length placeholder left in place, count/alignment preserved, no-op for non-positive
duration / no new paragraphs), the concatenation seam (`AudioConcatenatorTests` - a synthesized existing +
new fixture yields ONE longer valid file with the existing-duration reported and BOTH inputs untouched,
plus an empty new segment / unreadable input / mismatched format / verify-failure each falling back
safely), and the view-model wiring (`ResumeAudioViewModelTests` - a has-audio resume concatenates,
replaces the thought's audio, and offsets the new timings; a concatenation failure keeps the original
recording + text-only append with no data loss; a no-concatenator resume stays a text-only append). The
real audio concatenation on device is device-verified.
The generated scheme runs them.

## Design tokens

River Mist tokens are authored in Canopy's `roots` package and vendored as generated Swift
(`DesignSystem/Tokens.swift`). Views use `CanopyColor` / `CanopySpacing` / `CanopyRadius` /
`CanopyFont`; no hardcoded hex. Colors are dynamic (light/dark) and adapt to the system
appearance automatically. Re-sync steps live in the README.
