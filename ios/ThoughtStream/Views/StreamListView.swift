import SwiftUI

/// A destination on the Thoughts navigation stack (spec 0010). The stack is folder-aware: pushing a
/// `.folder(path)` opens that folder's contents screen (which recurses via `FolderContentsView`), and
/// pushing a `.note(note)` opens the existing note detail page. One enum route keeps folder navigation
/// and note navigation on the SAME stack, so the record-finished / resume flows still land on a note by
/// setting the path, and a back gesture walks folders and notes uniformly.
enum StreamRoute: Hashable {
    case folder([String])
    case note(Note)
    /// A brand-new, not-yet-persisted note (spec 0013) opened straight into the keyboard editor. It is
    /// a separate route from `.note` so the detail view knows to start in edit mode and to discard the
    /// note if the user backs out without typing. It becomes an ordinary saved note on first commit.
    case newNote(Note)
}

/// The notes feed: a folder-aware, sortable list of real saved notes on the River Mist palette, with
/// a toolbar (new-folder + sort + mic + gear) and a prominent record button that presents dictation.
/// Notes and folders load from the `NoteStore` and refresh after a dictation session or a folder edit.
///
/// This is the ROOT of the Thoughts `NavigationStack`. It owns the shared session/settings/playback
/// wiring and renders the root folder (`FolderContentsView(path: [])`) plus the `navigationDestination`
/// for both routes. `FolderContentsView` renders the same folder-list screen at any path, so a folder
/// pushed on the stack recurses into another instance of it.
struct StreamListView: View {
    private let store: NoteStoring
    private let makeTextProcessor: () -> TextProcessor
    private let settingsStore: SettingsStoring
    private let noteStoreKind: NoteStoreKind
    private let playbackController: NotePlaybackController?
    /// The feed model: owns the notes state, the off-main load, the iCloud observer wiring, and the
    /// folder CRUD / move seams. Shared by every `FolderContentsView` on the stack so a folder edit
    /// anywhere reloads the one list.
    @StateObject private var feed: StreamFeed
    /// The undoable-delete coordinator (spec 0020): every delete entry point (list swipe, list/detail
    /// menu) routes through it so the delete is soft (trashed, restorable), registered with the system
    /// UndoManager for Shake to Undo, and shown with the in-app undo affordance. Owned here at the root
    /// so the affordance is visible on the list even for a delete initiated from the note detail.
    @StateObject private var deletion: NoteDeletionController
    /// Whether the first-responder-backed `UndoManager` has been injected into the deletion controller
    /// yet (spec 0021 shake-to-undo fix), so the one-time injection from `UndoManagerHost` does not
    /// repeat. `@Environment(\.undoManager)` was unreliable (nil in plain SwiftUI), so a shake found no
    /// manager and "Undo Delete" did nothing; the host vends a STABLE manager the shake actually reaches.
    @State private var undoManagerInjected = false
    /// The scene phase, watched so a pending delete is COMMITTED when the app backgrounds (spec 0020):
    /// the undo window is a wall-clock affordance, and leaving a delete un-committed across a
    /// background/resume would keep trash around indefinitely (the timer is view-lifecycle-tied, not a
    /// background task). Committing on background makes "the window elapsed" cover backgrounding too.
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var sessionRoute: PendingSessionRoute
    @State private var showSettings = false
    /// The navigation stack path, a list of `StreamRoute`. A finished recording / resume sets this to
    /// land on the saved note (a fresh recording saves at top level, so we reset to just that note).
    @State private var path: [StreamRoute] = []
    /// Set when the user taps Resume on a note: presents a dictation session seeded with that note.
    @State private var resumeNote: Note?
    /// The global search query (spec 0021), owned here at the root so it survives navigation and a search
    /// started on the note-detail page can pop back to the root folder screen and drive the SAME flat
    /// global results. Bound into every `FolderContentsView`; the note detail routes into it via
    /// `onSearch`. Clearing it restores the normal folder view.
    @State private var searchQuery = ""
    /// The folder path a new dictation session should file its thought into (feedback: the record action
    /// must be contextual). Captured at the moment the Record/mic is tapped - which knows the current
    /// folder - because the dictation cover is presented at the root via `showDictation`, decoupled from
    /// which folder screen requested it. `[]` for a session started from the root or a hands-free entry
    /// point (Siri/CarPlay have no folder context).
    @State private var newThoughtFolderPath: [String] = []
    /// Drives the sort menu and the live re-sort. Seeded from persisted settings and written back on
    /// change so the choice survives a launch (spec 0010). Kept as view `@State` (not read straight
    /// off the store each render) so SwiftUI re-renders the list the instant it changes.
    @State private var sortOrder: NoteSortOrder

    private var showDictation: Binding<Bool> {
        Binding(
            get: { PendingSessionRoute.shouldPresent(startRequested: sessionRoute.startRequested) },
            set: { present in if !present { sessionRoute.consume() } }
        )
    }

    init(
        store: NoteStoring,
        makeTextProcessor: @escaping () -> TextProcessor,
        settingsStore: SettingsStoring,
        noteStoreKind: NoteStoreKind = .local,
        noteObserver: UbiquitousNoteObserving? = nil,
        sessionRoute: PendingSessionRoute,
        playbackController: NotePlaybackController? = nil
    ) {
        self.store = store
        self.makeTextProcessor = makeTextProcessor
        self.settingsStore = settingsStore
        self.noteStoreKind = noteStoreKind
        self.playbackController = playbackController
        self.sessionRoute = sessionRoute
        let feed = StreamFeed(store: store, observer: noteObserver)
        _feed = StateObject(wrappedValue: feed)
        _deletion = StateObject(wrappedValue: NoteDeletionController(feed: feed))
        _sortOrder = State(initialValue: settingsStore.noteSortOrder)
    }

    /// A fresh, empty note filed in `folderPath` (spec 0013), opened straight into the editor. It has
    /// no paragraphs and no custom title (its shown title derives once the user types), and it is not
    /// saved until the first non-empty commit.
    private func makeNewNote(in folderPath: [String]) -> Note {
        // Empty title -> the detail view derives one once the user types (spec 0009); non-custom.
        Note(title: "", paragraphs: [], createdAt: Date(), folderPath: folderPath)
    }

    /// Whether the note-detail resume icon applies for `note` per the audio-retention setting (spec
    /// 0021): resuming an existing recording always applies; recording onto a text-only note applies
    /// only when the retention policy records audio (a transcript-only note has no meaningful record
    /// action). Computed here at the composition root so the setting is read in one place and the view
    /// stays a thin caller.
    private func resumeApplies(for note: Note) -> Bool {
        note.hasAudio || settingsStore.audioRetention.recordsAudio
    }

    /// Route a search started on the note-detail page back to the list results (spec 0021): pop the
    /// whole stack to the ROOT folder screen and set the shared query, so the note page's search shows
    /// the SAME flat global results the folder screens do. Search is global, so the root is the natural
    /// place to present it.
    private func routeSearch(_ query: String) {
        path = []
        searchQuery = query
    }

    /// Start a new dictation session filed into `folderPath` (feedback: the record action is contextual):
    /// capture the folder the user is browsing NOW so the dictation cover - presented at the root - files
    /// the resulting thought there, then request the session through the shared route (the same seam
    /// Siri/CarPlay use, which pass `[]`).
    private func startNewThought(in folderPath: [String]) {
        newThoughtFolderPath = folderPath
        sessionRoute.startNewSession()
    }

    /// Apply the transcript reflow pass (spec 0016) to a note being SAVED AFTER AN EDIT. The gating -
    /// reflow only when `refineTranscript` is on, and only on this commit-edit path (never on load) -
    /// lives in the pure, tested `TranscriptCleanup.refinedForSave(_:refine:)`; this reads the current
    /// setting and delegates, so a load path can never reach it and an untouched note is never rewritten.
    private func refined(_ note: Note) -> Note {
        TranscriptCleanup.refinedForSave(note, refine: settingsStore.refineTranscript)
    }

    /// The dead-air trimmer for a new recording (spec 0019), or nil when the "Trim silences" setting is
    /// OFF. A nil trimmer means the view model touches no code path over the audio, so the recording is
    /// the byte-for-byte untrimmed capture. Read at build time so a Settings change applies to the next
    /// recording.
    private func makeAudioTrimmer() -> AudioTrimming? {
        settingsStore.trimSilence ? AudioTrimmer() : nil
    }

    /// Build a dictation view model for this session and wire its `onTrimmed` callback to reload the
    /// feed (spec 0019): a background dead-air trim re-saves the note's remapped timings off-main, so
    /// after it lands the feed must reload to drop the stale (un-remapped) in-memory note - otherwise
    /// playing the just-saved note would seek against timings that no longer match the shorter audio.
    private func makeDictationModel(
        recordsAudio: Bool,
        audioTrimmer: AudioTrimming?,
        folderPath: [String] = [],
        resuming: Note? = nil
    ) -> DictationViewModel {
        let model = DictationViewModel(
            store: store,
            processor: makeTextProcessor(),
            recordsAudio: recordsAudio,
            audioTrimmer: audioTrimmer,
            folderPath: folderPath,
            resuming: resuming
        )
        model.onTrimmed = { Task { await feed.reload() } }
        return model
    }

    var body: some View {
        NavigationStack(path: $path) {
            FolderContentsView(
                feed: feed,
                currentPath: [],
                sortOrder: $sortOrder,
                searchQuery: $searchQuery,
                playbackController: playbackController,
                onOpenFolder: { childPath in path.append(.folder(childPath)) },
                onOpenNote: { note in path.append(.note(note)) },
                onNewNote: { folderPath in path.append(.newNote(makeNewNote(in: folderPath))) },
                onNewThought: { folderPath in startNewThought(in: folderPath) },
                onOpenSettings: { showSettings = true },
                onDeleteNote: { id in Task { await deletion.delete(id: id) } },
                deletion: deletion
            )
            .navigationTitle("Thoughts")
            // The "Thoughts" title sits BELOW the toolbar buttons as a large title (spec 0021, revising
            // feedback 0016's inline choice): the user found the inline title smooshed under the buttons
            // and wanted it in a clear row below them, CONSISTENT with the folder screens (which use the
            // same large title). Both root and folder now read the same way.
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: StreamRoute.self) { route in
                switch route {
                case let .folder(folderPath):
                    // The SAME folder-list screen at a deeper path - recursion via a fresh instance.
                    FolderContentsView(
                        feed: feed,
                        currentPath: folderPath,
                        sortOrder: $sortOrder,
                        searchQuery: $searchQuery,
                        playbackController: playbackController,
                        onOpenFolder: { childPath in path.append(.folder(childPath)) },
                        onOpenNote: { note in path.append(.note(note)) },
                        onNewNote: { newPath in path.append(.newNote(makeNewNote(in: newPath))) },
                        onNewThought: { folderPath in startNewThought(in: folderPath) },
                        onOpenSettings: { showSettings = true },
                        onDeleteNote: { id in Task { await deletion.delete(id: id) } },
                        deletion: deletion
                    )
                    .navigationTitle(folderPath.last ?? "Thoughts")
                    // The folder name sits BELOW the toolbar buttons as a large title (spec 0021),
                    // matching the root "Thoughts" title instead of being smooshed inline under them.
                    .navigationBarTitleDisplayMode(.large)
                case let .note(note):
                    NoteDetailView(
                        note: note,
                        resolver: StoreAudioURLResolver(store: store),
                        controller: playbackController,
                        onNewThought: { folderPath in startNewThought(in: folderPath) },
                        onOpenSettings: { showSettings = true },
                        onResume: { current in resumeNote = current },
                        onCommitEdit: { edited in
                            Task {
                                _ = try? store.save(refined(edited))
                                await feed.reload()
                            }
                        },
                        onDelete: { id in
                            // Delete from detail (spec 0020): pop back to the list FIRST so the undo
                            // affordance shows there, then soft-delete through the shared undoable path.
                            if case .note = path.last { path.removeLast() }
                            Task { await deletion.delete(id: id) }
                        },
                        // Search from the note page routes to the SAME global results the list shows
                        // (spec 0021): pop to root and set the shared query.
                        onSearch: { query in routeSearch(query) },
                        // The resume icon shows only when resuming applies per the retention setting
                        // (spec 0021): always for a note that has audio, else only when audio is recorded.
                        resumeApplies: resumeApplies(for: note)
                    )
                case let .newNote(note):
                    // A fresh keyboard note (spec 0013): opens straight into the body editor. It is not
                    // on disk yet - `onCommitEdit` persists it on the first non-empty commit, and
                    // `onDiscardEmpty` deletes any provisional save and pops the route if the user backs
                    // out without typing, so no blank note is left behind.
                    NoteDetailView(
                        note: note,
                        resolver: StoreAudioURLResolver(store: store),
                        controller: playbackController,
                        onNewThought: { folderPath in startNewThought(in: folderPath) },
                        onOpenSettings: { showSettings = true },
                        onResume: { current in resumeNote = current },
                        onCommitEdit: { edited in
                            Task {
                                _ = try? store.save(refined(edited))
                                await feed.reload()
                            }
                        },
                        onDiscardEmpty: {
                            // Never persisted, so nothing to delete; just leave the stack. A guard on
                            // the top route avoids popping if the user already navigated elsewhere.
                            Task {
                                try? store.delete(id: note.id)
                                await feed.reload()
                            }
                            if case .newNote = path.last { path.removeLast() }
                        },
                        // Search is reachable from a brand-new note too (spec 0021); the resume icon
                        // stays hidden while the note is an unsaved empty draft (the view gates it).
                        onSearch: { query in routeSearch(query) },
                        startInEdit: true
                    )
                }
            }
            .fullScreenCover(isPresented: showDictation) {
                DictationView(
                    model: makeDictationModel(
                        recordsAudio: settingsStore.audioRetention.recordsAudio,
                        // Dead-air trimming (spec 0019): a trimmer only when the setting is on, so OFF
                        // leaves the recording byte-for-byte the untrimmed capture (nil trimmer = no
                        // code path touches the audio). Read at build time, so a Settings change applies
                        // to the next recording, like the other per-session settings.
                        audioTrimmer: makeAudioTrimmer(),
                        // File the new thought in the folder the user was browsing when they hit Record
                        // (feedback: the record action is contextual), captured in `startNewThought`.
                        folderPath: newThoughtFolderPath
                    )
                ) { savedNote in
                    // Land on the just-recorded thought by resetting the stack to just that note. It was
                    // filed in `newThoughtFolderPath` (the folder the user was in), so opening it and
                    // navigating back lands in that folder's list.
                    if let savedNote {
                        Task { await feed.reload() }
                        path = [.note(savedNote)]
                    }
                }
            }
            .fullScreenCover(item: $resumeNote) { note in
                DictationView(
                    model: makeDictationModel(
                        // A note with NO recording captures real audio when the user records into it
                        // (spec 0013), subject to the transcript-only retention setting; a note that
                        // already has audio stays text-only append so its original recording is intact.
                        recordsAudio: !note.hasAudio && settingsStore.audioRetention.recordsAudio,
                        // Only a note capturing a NEW recording (a text-only note recorded into) trims;
                        // a note that already has audio keeps its original recording untouched, and the
                        // view model only trims a freshly adopted recording anyway (spec 0019).
                        audioTrimmer: note.hasAudio ? nil : makeAudioTrimmer(),
                        resuming: note
                    )
                ) { savedNote in
                    if let savedNote {
                        Task { await feed.reload() }
                        path = [.note(savedNote)]
                    }
                    resumeNote = nil
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(settings: settingsStore, storeKind: noteStoreKind)
            }
        }
        .tint(CanopyColor.primary)
        // The in-app "Note deleted - Undo" affordance (spec 0020) now renders INSIDE each folder screen's
        // bottom stack (see `FolderContentsView.bottomStack`), reconciled with the persistent bottom bar
        // and now-playing bar (spec 0021): the three compose top-to-bottom in ONE safe-area inset via a
        // shared VStack, so the chip sits ABOVE the bottom bar with no hardcoded clearance and never
        // overlaps it. A delete from the note detail pops back to the list first (see `.note`'s onDelete),
        // where the affordance is visible. The window timer is lifecycle-tied there; the root keeps only
        // the UndoManager wiring (shake) and the background-commit below.
        //
        // Shake to Undo (spec 0021 fix): hand the deletion controller a STABLE, first-responder-backed
        // UndoManager from `UndoManagerHost` rather than `@Environment(\.undoManager)` (which is nil in
        // plain SwiftUI, so the shake found no registered action). The host is a zero-size background
        // representable that becomes first responder and vends the manager the shake gesture resolves;
        // injecting THAT manager makes registerUndo/undo/redo operate on what the shake actually uses.
        .background(
            UndoManagerHost { manager in
                guard !undoManagerInjected else { return }
                undoManagerInjected = true
                deletion.undoManager = manager
            }
        )
        // Commit any pending delete when the app leaves the foreground (spec 0020): the undo window is a
        // wall-clock affordance whose timer is view-lifecycle-tied, so backgrounding must close it rather
        // than leave the note un-committed in trash across a resume. Idempotent - a no-op with nothing
        // pending.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active { Task { await deletion.commitWindow() } }
        }
        // Persist the sort choice whenever it changes, so it survives a launch (spec 0010).
        .onChange(of: sortOrder) { _, newValue in settingsStore.noteSortOrder = newValue }
        .task {
            await withTaskCancellationHandler {
                // Opportunistically empty the trash on launch (spec 0020): any committed delete from a
                // prior run, or trash a crash left behind, has no pending undo this run and is purged.
                await deletion.purgeOrphanedTrashOnLaunch()
                await feed.start()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                }
            } onCancel: {
                Task { @MainActor in feed.stop() }
            }
        }
    }
}

/// The floating record button that opens the dictation screen.
struct RecordButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: CanopySpacing.x2) {
                Image(systemName: "mic.fill")
                Text("Record")
                    .font(.system(size: CanopyFont.sizeBase, weight: .semibold))
            }
            .foregroundStyle(CanopyColor.primaryForeground)
            .padding(.horizontal, CanopySpacing.x6)
            .padding(.vertical, CanopySpacing.x3)
            .background(CanopyColor.primary)
            .clipShape(Capsule())
            .shadow(color: CanopyColor.overlay.opacity(0.25), radius: 12, y: 6)
        }
    }
}

/// A brief, non-blocking banner shown when a note delete fails, styled with Canopy danger tokens.
struct DeleteFailedBanner: View {
    var body: some View {
        HStack(spacing: CanopySpacing.x2) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Could not delete note")
                .font(.system(size: CanopyFont.sizeSm, weight: .semibold))
        }
        .foregroundStyle(CanopyColor.dangerForeground)
        .padding(.horizontal, CanopySpacing.x4)
        .padding(.vertical, CanopySpacing.x2)
        .background(CanopyColor.danger)
        .clipShape(Capsule())
        .shadow(color: CanopyColor.overlay.opacity(0.2), radius: 8, y: 4)
        .padding(.top, CanopySpacing.x2)
    }
}

#Preview {
    StreamListView(
        store: NoteStore(),
        makeTextProcessor: { MiraTextProcessor() },
        settingsStore: UserDefaultsSettingsStore(),
        sessionRoute: PendingSessionRoute()
    )
}
