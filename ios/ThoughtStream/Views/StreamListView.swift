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
    /// The active scene's UndoManager, handed to the deletion controller so the system Shake to Undo
    /// gesture offers "Undo Delete". SwiftUI provides it through the environment; keeping
    /// `applicationSupportsShakeToEdit` at its default (true) is what makes the shake surface it.
    @Environment(\.undoManager) private var undoManager
    @ObservedObject private var sessionRoute: PendingSessionRoute
    @State private var showSettings = false
    /// The navigation stack path, a list of `StreamRoute`. A finished recording / resume sets this to
    /// land on the saved note (a fresh recording saves at top level, so we reset to just that note).
    @State private var path: [StreamRoute] = []
    /// Set when the user taps Resume on a note: presents a dictation session seeded with that note.
    @State private var resumeNote: Note?
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

    var body: some View {
        NavigationStack(path: $path) {
            FolderContentsView(
                feed: feed,
                currentPath: [],
                sortOrder: $sortOrder,
                playbackController: playbackController,
                onOpenFolder: { childPath in path.append(.folder(childPath)) },
                onOpenNote: { note in path.append(.note(note)) },
                onNewNote: { folderPath in path.append(.newNote(makeNewNote(in: folderPath))) },
                onNewThought: { sessionRoute.startNewSession() },
                onOpenSettings: { showSettings = true },
                onDeleteNote: { id in Task { await deletion.delete(id: id) } }
            )
            .navigationTitle("Thoughts")
            // Inline title (feedback 0016) so "Thoughts" sits on the SAME bar as the trailing mic/gear
            // buttons instead of on its own large-title row below them.
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: StreamRoute.self) { route in
                switch route {
                case let .folder(folderPath):
                    // The SAME folder-list screen at a deeper path - recursion via a fresh instance.
                    FolderContentsView(
                        feed: feed,
                        currentPath: folderPath,
                        sortOrder: $sortOrder,
                        playbackController: playbackController,
                        onOpenFolder: { childPath in path.append(.folder(childPath)) },
                        onOpenNote: { note in path.append(.note(note)) },
                        onNewNote: { newPath in path.append(.newNote(makeNewNote(in: newPath))) },
                        onNewThought: { sessionRoute.startNewSession() },
                        onOpenSettings: { showSettings = true },
                        onDeleteNote: { id in Task { await deletion.delete(id: id) } }
                    )
                    .navigationTitle(folderPath.last ?? "Thoughts")
                case let .note(note):
                    NoteDetailView(
                        note: note,
                        resolver: StoreAudioURLResolver(store: store),
                        controller: playbackController,
                        onNewThought: { sessionRoute.startNewSession() },
                        onOpenSettings: { showSettings = true },
                        onResume: { current in resumeNote = current },
                        onCommitEdit: { edited in
                            Task {
                                _ = try? store.save(edited)
                                await feed.reload()
                            }
                        },
                        onDelete: { id in
                            // Delete from detail (spec 0020): pop back to the list FIRST so the undo
                            // affordance shows there, then soft-delete through the shared undoable path.
                            if case .note = path.last { path.removeLast() }
                            Task { await deletion.delete(id: id) }
                        }
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
                        onNewThought: { sessionRoute.startNewSession() },
                        onOpenSettings: { showSettings = true },
                        onResume: { current in resumeNote = current },
                        onCommitEdit: { edited in
                            Task {
                                _ = try? store.save(edited)
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
                        startInEdit: true
                    )
                }
            }
            .fullScreenCover(isPresented: showDictation) {
                DictationView(
                    model: DictationViewModel(
                        store: store,
                        processor: makeTextProcessor(),
                        recordsAudio: settingsStore.audioRetention.recordsAudio
                    )
                ) { savedNote in
                    // A fresh recording saves at top level (folderPath []); land on it by resetting the
                    // stack to just that note, so the user sees what they recorded regardless of which
                    // folder they were browsing when they hit Record (spec 0010).
                    if let savedNote {
                        Task { await feed.reload() }
                        path = [.note(savedNote)]
                    }
                }
            }
            .fullScreenCover(item: $resumeNote) { note in
                DictationView(
                    model: DictationViewModel(
                        store: store,
                        processor: makeTextProcessor(),
                        // A note with NO recording captures real audio when the user records into it
                        // (spec 0013), subject to the transcript-only retention setting; a note that
                        // already has audio stays text-only append so its original recording is intact.
                        recordsAudio: !note.hasAudio && settingsStore.audioRetention.recordsAudio,
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
        // The in-app "Note deleted - Undo" affordance (spec 0020), hosted at the stack root so it shows
        // on the list even for a delete initiated from the note detail. Tapping Undo restores; letting
        // the ~5s window elapse commits the delete (purges the trashed files). Lifecycle-tied like the
        // copied-confirmation chip (no detached timer). Pinned near the bottom, clear of the toolbar.
        .undoDeleteAffordance(
            trigger: deletion.deleteTrigger,
            isPending: deletion.pending != nil,
            alignment: .bottom,
            onUndo: { Task { await deletion.undo() } },
            onExpire: { Task { await deletion.commitWindow() } }
        )
        // Hand the deletion controller the scene's UndoManager so Shake to Undo offers "Undo Delete".
        // Synced on appear and whenever SwiftUI swaps it in (it can be nil before the scene is ready).
        .onAppear { deletion.undoManager = undoManager }
        .onChange(of: undoManager == nil) { _, _ in deletion.undoManager = undoManager }
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
