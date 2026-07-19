import SwiftUI

/// A destination on the Thoughts navigation stack (spec 0010). The stack is folder-aware: pushing a
/// `.folder(path)` opens that folder's contents screen (which recurses via `FolderContentsView`), and
/// pushing a `.note(note)` opens the existing note detail page. One enum route keeps folder navigation
/// and note navigation on the SAME stack, so the record-finished / resume flows still land on a note by
/// setting the path, and a back gesture walks folders and notes uniformly.
enum StreamRoute: Hashable {
    case folder([String])
    case note(Note)
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
        _feed = StateObject(wrappedValue: StreamFeed(store: store, observer: noteObserver))
        _sortOrder = State(initialValue: settingsStore.noteSortOrder)
    }

    var body: some View {
        NavigationStack(path: $path) {
            FolderContentsView(
                feed: feed,
                currentPath: [],
                sortOrder: $sortOrder,
                onOpenFolder: { childPath in path.append(.folder(childPath)) },
                onOpenNote: { note in path.append(.note(note)) },
                onNewThought: { sessionRoute.startNewSession() },
                onOpenSettings: { showSettings = true }
            )
            .navigationTitle("Thoughts")
            .navigationDestination(for: StreamRoute.self) { route in
                switch route {
                case let .folder(folderPath):
                    // The SAME folder-list screen at a deeper path - recursion via a fresh instance.
                    FolderContentsView(
                        feed: feed,
                        currentPath: folderPath,
                        sortOrder: $sortOrder,
                        onOpenFolder: { childPath in path.append(.folder(childPath)) },
                        onOpenNote: { note in path.append(.note(note)) },
                        onNewThought: { sessionRoute.startNewSession() },
                        onOpenSettings: { showSettings = true }
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
                        }
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
                        recordsAudio: false,
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
        // Persist the sort choice whenever it changes, so it survives a launch (spec 0010).
        .onChange(of: sortOrder) { _, newValue in settingsStore.noteSortOrder = newValue }
        .task {
            await withTaskCancellationHandler {
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
