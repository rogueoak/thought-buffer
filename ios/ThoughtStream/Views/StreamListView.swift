import SwiftUI

/// A destination on the Thoughts navigation stack (spec 0010). The stack is folder-aware: pushing a
/// `.folder(path)` opens that folder's contents screen (which recurses via `FolderContentsView`), and
/// pushing a `.thought(thought)` opens the existing thought detail page. One enum route keeps folder navigation
/// and thought navigation on the SAME stack, so the record-finished / resume flows still land on a thought by
/// setting the path, and a back gesture walks folders and thoughts uniformly.
enum StreamRoute: Hashable {
    case folder([String])
    case thought(Thought)
    /// A brand-new, not-yet-persisted thought (spec 0013) opened straight into the keyboard editor. It is
    /// a separate route from `.thought` so the detail view knows to start in edit mode and to discard the
    /// thought if the user backs out without typing. It becomes an ordinary saved thought on first commit.
    case newThought(Thought)
}

/// The thoughts feed: a folder-aware, sortable list of real saved thoughts on the River Mist palette, with
/// a toolbar (new-folder + sort + mic + gear) and a prominent record button that presents dictation.
/// Thoughts and folders load from the `ThoughtStore` and refresh after a dictation session or a folder edit.
///
/// This is the ROOT of the Thoughts `NavigationStack`. It owns the shared session/settings/playback
/// wiring and renders the root folder (`FolderContentsView(path: [])`) plus the `navigationDestination`
/// for both routes. `FolderContentsView` renders the same folder-list screen at any path, so a folder
/// pushed on the stack recurses into another instance of it.
struct StreamListView: View {
    private let store: ThoughtStoring
    private let makeTextProcessor: () -> TextProcessor
    private let settingsStore: SettingsStoring
    private let thoughtStoreKind: ThoughtStoreKind
    private let playbackController: ThoughtPlaybackController?
    /// The feed model: owns the thoughts state, the off-main load, the iCloud observer wiring, and the
    /// folder CRUD / move seams. Shared by every `FolderContentsView` on the stack so a folder edit
    /// anywhere reloads the one list.
    @StateObject private var feed: StreamFeed
    /// The undoable-delete coordinator (spec 0020): every delete entry point (list swipe, list/detail
    /// menu) routes through it so the delete is soft (trashed, restorable), registered with the system
    /// UndoManager for Shake to Undo, and shown with the in-app undo affordance. Owned here at the root
    /// so the affordance is visible on the list even for a delete initiated from the thought detail.
    @StateObject private var deletion: ThoughtDeletionController
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
    /// The horizontal size class, driving the adaptive-navigation choice (spec 0022): REGULAR width (iPad,
    /// iPhone landscape where it fits) presents a `NavigationSplitView`; COMPACT keeps today's
    /// `NavigationStack`. The container choice is the pure, tested `StreamContainer.decide`.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var sessionRoute: PendingSessionRoute
    @State private var showSettings = false
    /// The navigation stack path, a list of `StreamRoute`. A finished recording / resume sets this to
    /// land on the saved thought (a fresh recording saves at top level, so we reset to just that thought).
    /// Used by the COMPACT `NavigationStack` (spec 0022); the split view drives navigation off
    /// `selectedFolder` (sidebar) + `contentPath` (content column) + `selectedRoute` (detail column).
    @State private var path: [StreamRoute] = []
    /// The folder selected in the split view's SIDEBAR (spec 0022): the content column shows this folder's
    /// thoughts. `[]` is the root (top-level) list. Its own `NavigationStack` (`contentPath`) handles
    /// pushing DEEPER folders inside the content column.
    @State private var selectedFolder: [String] = []
    /// The split view's CONTENT-column navigation stack (spec 0022): starts at `selectedFolder` and pushes
    /// deeper folder routes so nested folders navigate within the content column, while the sidebar keeps
    /// showing the root tree. Reset when the sidebar selection changes.
    @State private var contentPath: [StreamRoute] = []
    /// The thought (or new-thought draft) shown in the split view's DETAIL column (spec 0022). Set by a
    /// thought tap in the sidebar or content column; nil shows the detail-column placeholder.
    @State private var selectedRoute: StreamRoute?
    /// A monotonic counter bumped whenever the split view's active column changes (a sidebar folder or a
    /// detail thought selection), driving `UndoManagerHost` to re-home first responder so Shake to Undo
    /// keeps reaching the deletion controller's manager regardless of which column is active (spec 0022).
    @State private var undoReclaimTrigger = 0
    /// Whether the split view's SIDEBAR folders have loaded at least once (spec 0022), so the lifted
    /// projection gates on "folders loaded" like the compact `feed.didLoad && folderLoaded` gate and does
    /// not flash the empty-store CTA mid-load. Set from the sidebar's `onFoldersLoaded`.
    @State private var splitFoldersLoaded = false
    /// Set when the user taps Resume on a thought: presents a dictation session seeded with that thought.
    @State private var resumeThought: Thought?
    /// The global search query (spec 0021), owned here at the root so it survives navigation and a search
    /// started on the thought-detail page can pop back to the root folder screen and drive the SAME flat
    /// global results. Bound into every `FolderContentsView`; the thought detail routes into it via
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
    @State private var sortOrder: ThoughtSortOrder

    private var showDictation: Binding<Bool> {
        Binding(
            get: { PendingSessionRoute.shouldPresent(startRequested: sessionRoute.startRequested) },
            set: { present in if !present { sessionRoute.consume() } }
        )
    }

    init(
        store: ThoughtStoring,
        makeTextProcessor: @escaping () -> TextProcessor,
        settingsStore: SettingsStoring,
        thoughtStoreKind: ThoughtStoreKind = .local,
        thoughtObserver: UbiquitousThoughtObserving? = nil,
        sessionRoute: PendingSessionRoute,
        playbackController: ThoughtPlaybackController? = nil
    ) {
        self.store = store
        self.makeTextProcessor = makeTextProcessor
        self.settingsStore = settingsStore
        self.thoughtStoreKind = thoughtStoreKind
        self.playbackController = playbackController
        self.sessionRoute = sessionRoute
        let feed = StreamFeed(store: store, observer: thoughtObserver)
        _feed = StateObject(wrappedValue: feed)
        _deletion = StateObject(wrappedValue: ThoughtDeletionController(feed: feed))
        _sortOrder = State(initialValue: settingsStore.thoughtSortOrder)
    }

    /// A fresh, empty thought filed in `folderPath` (spec 0013), opened straight into the editor. It has
    /// no paragraphs and no custom title (its shown title derives once the user types), and it is not
    /// saved until the first non-empty commit.
    private func makeNewThought(in folderPath: [String]) -> Thought {
        // Empty title -> the detail view derives one once the user types (spec 0009); non-custom.
        Thought(title: "", paragraphs: [], createdAt: Date(), folderPath: folderPath)
    }

    /// Whether the thought-detail resume icon applies for `thought` per the audio-retention setting (spec
    /// 0021): resuming an existing recording always applies; recording onto a text-only thought applies
    /// only when the retention policy records audio (a transcript-only thought has no meaningful record
    /// action). Computed here at the composition root so the setting is read in one place and the view
    /// stays a thin caller.
    private func resumeApplies(for thought: Thought) -> Bool {
        thought.hasAudio || settingsStore.audioRetention.recordsAudio
    }

    /// Route a search started on the thought-detail page back to the list results (spec 0021): land on the
    /// ROOT folder screen showing the SAME flat global results the folder screens do (search is global). In
    /// the COMPACT stack this pops the whole stack; in the SPLIT view it points the content column at the
    /// root and closes the detail column, so the shared results replace the detail. Only the compact
    /// thought-detail bar carries its own search field - the split detail column defers to the always-visible
    /// lifted bar (spec 0022) - so this is reached from compact today, and stays correct for both.
    private func routeSearch(_ query: String) {
        switch StreamContainer.decide(horizontalSizeClass: horizontalSizeClass) {
        case .stack:
            path = []
        case .split:
            selectSidebarFolder([])
            selectedRoute = nil
        }
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

    /// Apply the transcript reflow pass (spec 0016) to a thought being SAVED AFTER AN EDIT. The gating -
    /// reflow only when `refineTranscript` is on, and only on this commit-edit path (never on load) -
    /// lives in the pure, tested `TranscriptCleanup.refinedForSave(_:refine:)`; this reads the current
    /// setting and delegates, so a load path can never reach it and an untouched thought is never rewritten.
    private func refined(_ thought: Thought) -> Thought {
        TranscriptCleanup.refinedForSave(thought, refine: settingsStore.refineTranscript)
    }

    /// The dead-air trimmer for a new recording (spec 0019), or nil when the "Trim silences" setting is
    /// OFF. A nil trimmer means the view model touches no code path over the audio, so the recording is
    /// the byte-for-byte untrimmed capture. Read at build time so a Settings change applies to the next
    /// recording.
    private func makeAudioTrimmer() -> AudioTrimming? {
        settingsStore.trimSilence ? AudioTrimmer() : nil
    }

    /// Build a dictation view model for this session and wire its `onTrimmed` callback to reload the
    /// feed (spec 0019): a background dead-air trim re-saves the thought's remapped timings off-main, so
    /// after it lands the feed must reload to drop the stale (un-remapped) in-memory thought - otherwise
    /// playing the just-saved thought would seek against timings that no longer match the shorter audio.
    private func makeDictationModel(
        recordsAudio: Bool,
        audioTrimmer: AudioTrimming?,
        folderPath: [String] = [],
        resuming: Thought? = nil
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
        // The adaptive-navigation choice (spec 0022): a pure decision on the horizontal size class picks
        // the split view (regular width) or the stack (compact). Both share the same route model,
        // dictation / resume covers, Settings sheet, UndoManager host, and lifecycle task below.
        let container = StreamContainer.decide(horizontalSizeClass: horizontalSizeClass)
        return Group {
            switch container {
            case .split:
                splitView
            case .stack:
                compactStack
            }
        }
        // The dictation / resume / settings presentations are shared across both containers (spec 0022):
        // the record action, a resume, and Settings behave identically whether the split view or the stack
        // is active. Applied here (above the container) so neither container forks them.
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
            ) { savedThought in
                // Land on the just-recorded thought. It was filed in `newThoughtFolderPath` (the folder the
                // user was in), so opening it and navigating back lands in that folder's list.
                if let savedThought {
                    Task { await feed.reload() }
                    landOnThought(savedThought)
                }
            }
        }
        .fullScreenCover(item: $resumeThought) { thought in
            DictationView(
                model: makeDictationModel(
                    // A thought with NO recording captures real audio when the user records into it
                    // (spec 0013), subject to the transcript-only retention setting; a thought that
                    // already has audio stays text-only append so its original recording is intact.
                    recordsAudio: !thought.hasAudio && settingsStore.audioRetention.recordsAudio,
                    // Only a thought capturing a NEW recording (a text-only thought recorded into) trims;
                    // a thought that already has audio keeps its original recording untouched, and the
                    // view model only trims a freshly adopted recording anyway (spec 0019).
                    audioTrimmer: thought.hasAudio ? nil : makeAudioTrimmer(),
                    resuming: thought
                )
            ) { savedThought in
                if let savedThought {
                    Task { await feed.reload() }
                    landOnThought(savedThought)
                }
                resumeThought = nil
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settingsStore, storeKind: thoughtStoreKind)
        }
        .tint(CanopyColor.primary)
        // The in-app "Thought deleted - Undo" affordance (spec 0020) now renders INSIDE each folder screen's
        // bottom stack (see `FolderContentsView.bottomStack`), reconciled with the persistent bottom bar
        // and now-playing bar (spec 0021): the three compose top-to-bottom in ONE safe-area inset via a
        // shared VStack, so the chip sits ABOVE the bottom bar with no hardcoded clearance and never
        // overlaps it. A delete from the thought detail pops back to the list first (see `.thought`'s onDelete),
        // where the affordance is visible. The window timer is lifecycle-tied there; the root keeps only
        // the UndoManager wiring (shake) and the background-commit below.
        //
        // Shake to Undo (spec 0021 fix): hand the deletion controller a STABLE, first-responder-backed
        // UndoManager from `UndoManagerHost` rather than `@Environment(\.undoManager)` (which is nil in
        // plain SwiftUI, so the shake found no registered action). The host is a zero-size background
        // representable that becomes first responder and vends the manager the shake gesture resolves;
        // injecting THAT manager makes registerUndo/undo/redo operate on what the shake actually uses.
        .background(
            UndoManagerHost(
                onManager: { manager in
                    guard !undoManagerInjected else { return }
                    undoManagerInjected = true
                    deletion.undoManager = manager
                },
                // Re-home first responder when the split view's active column changes (spec 0022), so a
                // shake keeps reaching the vended manager after focus moved between columns. Stays 0 (a
                // no-op) on the compact stack.
                reclaimTrigger: undoReclaimTrigger,
                // While a delete is pending, let the host self-heal first responder on a layout pass
                // (rotate / resize / multitasking) so the shake still recovers even when no column selection
                // changed (spec 0022).
                pendingDelete: deletion.pending != nil
            )
        )
        // Bump the re-home trigger on a split-view column change (spec 0022 UndoManagerHost re-home): the
        // sidebar folder or the detail thought selection moving the active column fires no text/keyboard
        // notification, so signal the host to re-claim first responder for the shake gesture.
        .onChange(of: selectedFolder) { _, _ in undoReclaimTrigger += 1 }
        .onChange(of: selectedRoute) { _, _ in undoReclaimTrigger += 1 }
        // Commit any pending delete when the app leaves the foreground (spec 0020): the undo window is a
        // wall-clock affordance whose timer is view-lifecycle-tied, so backgrounding must close it rather
        // than leave the thought un-committed in trash across a resume. Idempotent - a no-op with nothing
        // pending.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active { Task { await deletion.commitWindow() } }
        }
        // Persist the sort choice whenever it changes, so it survives a launch (spec 0010).
        .onChange(of: sortOrder) { _, newValue in settingsStore.thoughtSortOrder = newValue }
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

    // MARK: - Compact container (NavigationStack) - unchanged iPhone behavior

    /// The COMPACT-width container (spec 0022): today's single `NavigationStack`, one folder/thought screen
    /// at a time, its route destinations, and its own per-screen bottom bar (via `FolderContentsView`'s
    /// default `showsBottomBar: true`). Extracted verbatim from the pre-0022 body so iPhone behavior is
    /// unchanged; the shared covers/sheet + UndoManager host + lifecycle task apply above it in `body`.
    private var compactStack: some View {
        NavigationStack(path: $path) {
            FolderContentsView(
                feed: feed,
                currentPath: [],
                sortOrder: $sortOrder,
                searchQuery: $searchQuery,
                playbackController: playbackController,
                onOpenFolder: { childPath in path.append(.folder(childPath)) },
                onOpenThought: { thought in path.append(.thought(thought)) },
                onNewKeyboardThought: { folderPath in path.append(.newThought(makeNewThought(in: folderPath))) },
                onNewThought: { folderPath in startNewThought(in: folderPath) },
                onOpenSettings: { showSettings = true },
                onDeleteThought: { id in Task { await deletion.delete(id: id) } },
                deletion: deletion,
                // Bar ownership is the tested `StreamContainer` decision, not a raw literal (spec 0022): the
                // compact stack's one-screen-at-a-time folder screen owns its bottom bar.
                showsBottomBar: StreamContainer.stack.folderScreenShowsOwnBottomBar
            )
            .navigationTitle("Thoughts")
            // The "Thoughts" title sits BELOW the toolbar buttons as a large title (spec 0021, revising
            // feedback 0016's inline choice), CONSISTENT with the folder screens.
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
                        onOpenThought: { thought in path.append(.thought(thought)) },
                        onNewKeyboardThought: { newPath in path.append(.newThought(makeNewThought(in: newPath))) },
                        onNewThought: { folderPath in startNewThought(in: folderPath) },
                        onOpenSettings: { showSettings = true },
                        onDeleteThought: { id in Task { await deletion.delete(id: id) } },
                        deletion: deletion,
                        showsBottomBar: StreamContainer.stack.folderScreenShowsOwnBottomBar
                    )
                    .navigationTitle(folderPath.last ?? "Thoughts")
                    .navigationBarTitleDisplayMode(.large)
                default:
                    // A thought / new-thought route uses the SHARED detail builder so the compact stack and
                    // the split detail column construct the same view (spec 0022): the detail's edit/delete/
                    // search/resume wiring lives in one place.
                    detailView(for: route, onPopThought: { if case .thought = path.last { path.removeLast() } },
                               onPopNewThought: { if case .newThought = path.last { path.removeLast() } })
                }
            }
        }
    }

    // MARK: - Split container (NavigationSplitView) - iPad / regular width (spec 0022)

    /// The REGULAR-width container (spec 0022): a three-column `NavigationSplitView` - the root folder tree
    /// in the SIDEBAR, the selected folder's thoughts in the CONTENT column (its own stack so nested folders
    /// push there), and the selected thought in the DETAIL column. The bottom bar + search + undo chip are
    /// LIFTED here, above the columns, into ONE shared surface (the 0021-review requirement): both the
    /// sidebar and content columns render their lists WITHOUT their own bottom bar (`showsBottomBar: false`),
    /// and they share the ONE `StreamSearchProjection` computed once here, so there is a single search field
    /// and one flat results list across the whole split view.
    private var splitView: some View {
        // ONE search projection for the whole split view (spec 0022): both columns render from this, so the
        // shared query drives a single results list instead of two fields fighting one state. Scanned once.
        // Gated on `feed.didLoad && splitFoldersLoaded` (matching the compact `feed.didLoad && folderLoaded`
        // gate) so the split view does not flash the empty-store CTA mid-load.
        let projection = StreamSearchProjection.resolve(
            didLoad: feed.didLoad && splitFoldersLoaded,
            thoughts: feed.thoughts,
            searchQuery: searchQuery
        )
        return NavigationSplitView {
            splitSidebar(projection: projection)
        } content: {
            splitContent(projection: projection)
        } detail: {
            splitDetail
        }
        // The lifted bottom stack for the whole split view (spec 0022 required restructure): the single
        // search field, the now-playing bar, the undo chip, and the record/new-thought actions live here,
        // above the columns, so there is ONE search surface across the sidebar and content columns. It is
        // the SAME `StreamBottomStack` the compact folder screen renders (de-duped, one component).
        .safeAreaInset(edge: .bottom) {
            liftedBottomStack(state: projection.state)
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// The split-view SIDEBAR: the root folder tree (top-level folders + thoughts). A folder tap selects it
    /// (the content column shows its thoughts); a thought tap routes it to the detail column. Renders no
    /// bottom bar - the lifted stack owns it. During an active search the sidebar keeps its NORMAL folder
    /// tree (via `sidebarProjection`), so the ONE global results list shows only in the content column, not
    /// double-rendered here beside it (spec 0022 fix).
    private func splitSidebar(projection: StreamSearchProjection.Result) -> some View {
        FolderContentsView(
            feed: feed,
            currentPath: [],
            sortOrder: $sortOrder,
            searchQuery: $searchQuery,
            playbackController: playbackController,
            onOpenFolder: { childPath in selectSidebarFolder(childPath) },
            onOpenThought: { thought in selectedRoute = .thought(thought) },
            onNewKeyboardThought: { folderPath in selectedRoute = .newThought(makeNewThought(in: folderPath)) },
            onNewThought: { folderPath in startNewThought(in: folderPath) },
            onOpenSettings: { showSettings = true },
            onDeleteThought: { id in deleteThoughtFromSplit(id) },
            deletion: deletion,
            showsBottomBar: StreamContainer.split.folderScreenShowsOwnBottomBar,
            resolvedContent: StreamSearchProjection.sidebarProjection(from: projection),
            onFoldersLoaded: { splitFoldersLoaded = true }
        )
        .navigationTitle("Thoughts")
        .navigationBarTitleDisplayMode(.large)
    }

    /// The split-view CONTENT column: the selected folder's thoughts, in its OWN `NavigationStack` so nested
    /// folders push within this column (the sidebar keeps the root tree). A thought tap routes it to the
    /// detail column. Renders no bottom bar - the lifted stack owns it.
    private func splitContent(projection: StreamSearchProjection.Result) -> some View {
        NavigationStack(path: $contentPath) {
            folderColumn(path: selectedFolder, projection: projection)
                .navigationDestination(for: StreamRoute.self) { route in
                    if case let .folder(folderPath) = route {
                        // A deeper folder navigates within the content column; its search state is the SAME
                        // shared projection, so a search shows one flat results list column-wide too.
                        folderColumn(path: folderPath, projection: projection)
                    }
                }
        }
    }

    /// One folder screen in the split view's content column, at `path`, bottom-bar-free and driven by the
    /// shared search projection. A folder tap pushes deeper in the content stack; a thought tap opens the
    /// detail column.
    private func folderColumn(path folderPath: [String], projection: StreamSearchProjection.Result) -> some View {
        FolderContentsView(
            feed: feed,
            currentPath: folderPath,
            sortOrder: $sortOrder,
            searchQuery: $searchQuery,
            playbackController: playbackController,
            onOpenFolder: { childPath in contentPath.append(.folder(childPath)) },
            onOpenThought: { thought in selectedRoute = .thought(thought) },
            onNewKeyboardThought: { newPath in selectedRoute = .newThought(makeNewThought(in: newPath)) },
            onNewThought: { newPath in startNewThought(in: newPath) },
            onOpenSettings: { showSettings = true },
            onDeleteThought: { id in deleteThoughtFromSplit(id) },
            deletion: deletion,
            // The content column shows the ONE global results list during an active search (the sidebar
            // stays normal), so it takes the FULL projection.
            showsBottomBar: StreamContainer.split.folderScreenShowsOwnBottomBar,
            resolvedContent: projection
        )
        .navigationTitle(folderPath.last ?? "Thoughts")
        .navigationBarTitleDisplayMode(.large)
    }

    /// The split-view DETAIL column: the selected thought (or new-thought draft), or a centered placeholder
    /// when nothing is selected. A delete clears the selection (there is no stack to pop in this column).
    @ViewBuilder
    private var splitDetail: some View {
        if let selectedRoute {
            NavigationStack {
                detailView(
                    for: selectedRoute,
                    // The split detail column defers search to the always-visible lifted bar (spec 0022),
                    // so it drops its own search field to avoid two competing fields.
                    showsDetailSearch: false,
                    onPopThought: { self.selectedRoute = nil },
                    onPopNewThought: { self.selectedRoute = nil }
                )
            }
        } else {
            SplitDetailPlaceholder()
        }
    }

    // MARK: - Shared detail builder + lifted bottom stack

    /// Build the thought / new-thought detail view for a route (spec 0022), shared by the compact stack's
    /// destination and the split view's detail column so the edit / delete / search / resume wiring is
    /// defined ONCE. `onPopThought` / `onPopNewThought` are how the host dismisses the detail after a delete
    /// or an empty-draft discard - the compact stack pops its path, the split column clears its selection.
    @ViewBuilder
    private func detailView(
        for route: StreamRoute,
        showsDetailSearch: Bool = true,
        onPopThought: @escaping () -> Void,
        onPopNewThought: @escaping () -> Void
    ) -> some View {
        // Whether THIS detail carries its own search field (spec 0022): the COMPACT stack does (its
        // one-screen-at-a-time bottom bar is the only search surface on the thought page). The SPLIT detail
        // column does NOT - the lifted bottom bar is always visible above all columns, so a second search
        // field would be the two-competing-fields bug. Passing nil `onSearch` drops the detail search field
        // via the pure `ThoughtDetailBottomBar` decision while keeping the resume icon.
        let onSearch: ((String) -> Void)? = showsDetailSearch ? { query in routeSearch(query) } : nil
        switch route {
        case let .thought(thought):
            ThoughtDetailView(
                thought: thought,
                resolver: StoreAudioURLResolver(store: store),
                controller: playbackController,
                onNewThought: { folderPath in startNewThought(in: folderPath) },
                onOpenSettings: { showSettings = true },
                onResume: { current in resumeThought = current },
                onCommitEdit: { edited in
                    Task {
                        _ = try? store.save(refined(edited))
                        await feed.reload()
                    }
                },
                onDelete: { id in
                    // Delete from detail (spec 0020): dismiss the detail FIRST so the undo affordance shows
                    // on the list, then soft-delete through the shared undoable path.
                    onPopThought()
                    Task { await deletion.delete(id: id) }
                },
                // Search from the thought page routes to the SAME global results the list shows (spec 0021).
                onSearch: onSearch,
                resumeApplies: resumeApplies(for: thought)
            )
        case let .newThought(thought):
            // A fresh keyboard thought (spec 0013): opens straight into the body editor, not yet on disk.
            ThoughtDetailView(
                thought: thought,
                resolver: StoreAudioURLResolver(store: store),
                controller: playbackController,
                onNewThought: { folderPath in startNewThought(in: folderPath) },
                onOpenSettings: { showSettings = true },
                onResume: { current in resumeThought = current },
                onCommitEdit: { edited in
                    Task {
                        _ = try? store.save(refined(edited))
                        await feed.reload()
                    }
                },
                onDiscardEmpty: {
                    Task {
                        try? store.delete(id: thought.id)
                        await feed.reload()
                    }
                    onPopNewThought()
                },
                onSearch: onSearch,
                startInEdit: true
            )
        case .folder:
            // A folder route is never a detail; the folder columns handle it. EmptyView keeps the switch total.
            EmptyView()
        }
    }

    /// The LIFTED bottom stack for the split view (spec 0022 required restructure): the ONE search field +
    /// record/new-thought actions, the now-playing bar, and the undo-delete chip, composed above BOTH
    /// columns so there is a single search surface across the whole split view (not one per column). It is
    /// the SAME `StreamBottomStack` component the compact folder screen renders (de-duped, one place for the
    /// composition + the 5s undo-window timer); the record/new-thought actions file into the folder
    /// currently selected in the sidebar.
    private func liftedBottomStack(state screenState: FolderScreenState) -> some View {
        StreamBottomStack(
            query: $searchQuery,
            screenState: screenState,
            deletion: deletion,
            playbackController: playbackController,
            onOpenThought: { selectedRoute = .thought($0) },
            onNewKeyboardThought: { selectedRoute = .newThought(makeNewThought(in: selectedFolder)) },
            onNewThought: { startNewThought(in: selectedFolder) }
        )
        // The lifted bar sits above BOTH columns, so it inherits the split's full width; the horizontal
        // inset keeps the capsule from spanning edge-to-edge on the wide canvas.
        .padding(.horizontal, CanopySpacing.x4)
    }

    /// Delete a thought from the split view (spec 0022): reconcile the DETAIL column first - if the deleted
    /// thought is the one currently open there, clear the selection so the user cannot keep reading / editing
    /// / resuming a trashed thought (the pure `SplitDetailReconcile` decides) - then soft-delete through the
    /// shared undoable path. The undo chip shows in the lifted bar regardless of which column initiated it.
    private func deleteThoughtFromSplit(_ id: UUID) {
        if SplitDetailReconcile.deleteClearsSelection(deletedId: id, shownThoughtId: selectedThoughtId) {
            selectedRoute = nil
        }
        Task { await deletion.delete(id: id) }
    }

    /// The persisted id of the thought currently shown in the detail column, or nil when the column shows the
    /// placeholder or an unsaved new-thought draft (which has no id to delete against).
    private var selectedThoughtId: UUID? {
        if case let .thought(thought) = selectedRoute { return thought.id }
        return nil
    }

    /// Select a folder in the split view's sidebar: point the content column at it, reset that column's own
    /// navigation stack, AND clear the detail column - the previously-open thought belonged to the old
    /// folder's context, so a fresh folder starts with no thought selected (spec 0022, so folder B does not
    /// leave folder A's thought open in detail).
    private func selectSidebarFolder(_ folderPath: [String]) {
        selectedFolder = folderPath
        contentPath = []
        selectedRoute = nil
    }

    /// Land on a just-saved thought from a dictation / resume session, in whichever container is active
    /// (spec 0022): the compact stack resets its path to that thought; the split view selects it in the
    /// detail column. A fresh recording saved at top level, so the split view also points the sidebar at
    /// the root.
    private func landOnThought(_ thought: Thought) {
        let container = StreamContainer.decide(horizontalSizeClass: horizontalSizeClass)
        switch container {
        case .stack:
            path = [.thought(thought)]
        case .split:
            selectSidebarFolder(thought.folderPath)
            selectedRoute = .thought(thought)
        }
    }
}

/// The split-view detail-column placeholder shown when no thought is selected (spec 0022): a centered
/// waveform + prompt, sized for a wide canvas, so the empty detail column reads as intentional rather than
/// blank. Uses the same Canopy tokens as the folder empty state.
struct SplitDetailPlaceholder: View {
    var body: some View {
        VStack(spacing: CanopySpacing.x4) {
            Image(systemName: "waveform")
                .font(.system(size: CanopyFont.sizeX4xl, weight: .semibold))
                .foregroundStyle(CanopyColor.primary)
            Text("Select a thought")
                .font(.system(size: CanopyFont.sizeXl, weight: .semibold))
                .foregroundStyle(CanopyColor.text)
            Text("Pick a thought from the list to read or edit it, or record a new one.")
                .font(.system(size: CanopyFont.sizeSm))
                .foregroundStyle(CanopyColor.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CanopySpacing.x8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CanopyColor.bg.ignoresSafeArea())
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

/// A brief, non-blocking banner shown when a thought delete fails, styled with Canopy danger tokens.
struct DeleteFailedBanner: View {
    var body: some View {
        HStack(spacing: CanopySpacing.x2) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Could not delete thought")
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
        store: ThoughtStore(),
        makeTextProcessor: { MiraTextProcessor() },
        settingsStore: UserDefaultsSettingsStore(),
        sessionRoute: PendingSessionRoute()
    )
}
