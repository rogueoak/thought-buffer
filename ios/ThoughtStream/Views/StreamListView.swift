import SwiftUI

/// A destination on the Thoughts navigation (spec 0010, remodeled by spec 0026). The redesigned model is
/// FOLDERS-ONLY at the top level and one level deep: the top-level screen (`TopLevelFoldersView`) shows the
/// two virtual alias folders (All Thoughts, Recents) then the user's folders, and opening any of them pushes
/// a FLAT thought list (`FolderThoughtsView`). `.thought` / `.newThought` open the thought detail. One enum
/// route keeps folder navigation and thought navigation on the SAME stack, so the record-finished / resume
/// flows land on a thought by setting the path, and a back gesture walks folders and thoughts uniformly.
enum StreamRoute: Hashable {
    /// A top-level user folder (spec 0026: one level deep, so the path is a single `[name]`).
    case folder([String])
    /// A virtual alias folder - All Thoughts or Recents - a pure projection over the loaded thoughts.
    case alias(AliasFolder)
    case thought(Thought)
    /// A brand-new, not-yet-persisted thought (spec 0013) opened straight into the keyboard editor. It is
    /// a separate route from `.thought` so the detail view knows to start in edit mode and to discard the
    /// thought if the user backs out without typing. It becomes an ordinary saved thought on first commit.
    case newThought(Thought)
}

/// The thoughts feed: a folders-only top level (spec 0026) with two pinned virtual alias folders (All
/// Thoughts, Recents) then the user's folders, a toolbar (new-folder + sort + gear) and a persistent bottom
/// bar (search + new-thought + record). Thoughts and folders load from the `ThoughtStore` and refresh after
/// a dictation session or a folder edit.
///
/// This is the ROOT of the Thoughts navigation. It owns the shared session/settings/playback wiring and
/// renders the top-level folders screen plus the `navigationDestination` for the routes: a `.folder` /
/// `.alias` opens a flat `FolderThoughtsView`, a `.thought` / `.newThought` opens the detail.
struct StreamListView: View {
    private let store: ThoughtStoring
    private let makeTextProcessor: () -> TextProcessor
    private let settingsStore: SettingsStoring
    private let thoughtStoreKind: ThoughtStoreKind
    private let playbackController: ThoughtPlaybackController?
    /// The feed model: owns the thoughts state, the off-main load, the iCloud observer wiring, and the
    /// folder CRUD / move seams. Shared by every folder / thought screen so an edit anywhere reloads the one
    /// list.
    @StateObject private var feed: StreamFeed
    /// The undoable-delete coordinator (spec 0020): every delete entry point routes through it so the delete
    /// is soft (trashed, restorable), registered with the system UndoManager for Shake to Undo, and shown
    /// with the in-app undo affordance. Owned here at the root so the affordance is visible on the list even
    /// for a delete initiated from the thought detail.
    @StateObject private var deletion: ThoughtDeletionController
    @State private var undoManagerInjected = false
    @Environment(\.scenePhase) private var scenePhase
    /// The horizontal size class, driving the adaptive-navigation choice (spec 0022).
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var sessionRoute: PendingSessionRoute
    @State private var showSettings = false
    /// The COMPACT-width navigation stack path.
    @State private var path: [StreamRoute] = []
    /// The subject selected in the split view's SIDEBAR (spec 0022 + 0026): the content column shows this
    /// folder / alias's flat thought list. Nil shows a placeholder in the content column.
    @State private var selectedSubject: FolderSubject?
    /// The thought (or new-thought draft) shown in the split view's DETAIL column (spec 0022).
    @State private var selectedRoute: StreamRoute?
    @State private var undoReclaimTrigger = 0
    /// Whether the split view's SIDEBAR folders have loaded at least once (spec 0022), gating the lifted
    /// projection so it does not flash the empty-store CTA mid-load.
    @State private var splitFoldersLoaded = false
    @State private var resumeThought: Thought?
    /// The global search query (spec 0021), owned here so it survives navigation and a search started on the
    /// thought-detail page can pop back to the top-level screen and drive the SAME flat global results.
    @State private var searchQuery = ""
    /// The folder path a new dictation session should file its thought into (spec 0026): captured when
    /// Record/mic is tapped. Inside a user folder -> `[name]`; from the top level / All / Recents / a
    /// hands-free entry point -> `[]` (uncategorized). The placement decision is the pure
    /// `NewThoughtPlacement`, applied by each screen before it calls up.
    @State private var newThoughtFolderPath: [String] = []
    /// Drives the sort menu and the live re-sort. Seeded from persisted settings and written back on change.
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
        playbackController: ThoughtPlaybackController? = nil,
        watchCoordinator: PhoneConnectivityCoordinator? = nil
    ) {
        self.store = store
        self.makeTextProcessor = makeTextProcessor
        self.settingsStore = settingsStore
        self.thoughtStoreKind = thoughtStoreKind
        self.playbackController = playbackController
        self.sessionRoute = sessionRoute
        let feed = StreamFeed(store: store, observer: thoughtObserver)
        if let watchCoordinator {
            feed.onThoughtsChanged = { _ in watchCoordinator.pushRecentThoughts() }
        }
        _feed = StateObject(wrappedValue: feed)
        _deletion = StateObject(wrappedValue: ThoughtDeletionController(feed: feed))
        _sortOrder = State(initialValue: settingsStore.thoughtSortOrder)
    }

    /// A fresh, empty thought filed in `folderPath` (spec 0013), opened straight into the editor.
    private func makeNewThought(in folderPath: [String]) -> Thought {
        Thought(title: "", paragraphs: [], createdAt: Date(), folderPath: folderPath)
    }

    /// Whether the thought-detail resume icon applies for `thought` per the audio-retention setting.
    private func resumeApplies(for thought: Thought) -> Bool {
        thought.hasAudio || settingsStore.audioRetention.recordsAudio
    }

    /// Start a new dictation session filed into `folderPath` (spec 0026): capture the placement the calling
    /// screen resolved (`NewThoughtPlacement`), then request the session through the shared route.
    private func startNewThought(in folderPath: [String]) {
        newThoughtFolderPath = folderPath
        sessionRoute.startNewSession()
    }

    private func refined(_ thought: Thought) -> Thought {
        TranscriptCleanup.refinedForSave(thought, refine: settingsStore.refineTranscript)
    }

    private func makeAudioTrimmer() -> AudioTrimming? {
        settingsStore.trimSilence ? AudioTrimmer() : nil
    }

    private func makeAudioConcatenator(for thought: Thought) -> AudioConcatenating? {
        (thought.hasAudio && settingsStore.audioRetention.recordsAudio) ? AudioConcatenator() : nil
    }

    private func makeDictationModel(
        recordsAudio: Bool,
        audioTrimmer: AudioTrimming?,
        audioConcatenator: AudioConcatenating? = nil,
        folderPath: [String] = [],
        resuming: Thought? = nil
    ) -> DictationViewModel {
        let model = DictationViewModel(
            store: store,
            processor: makeTextProcessor(),
            recordsAudio: recordsAudio,
            audioTrimmer: audioTrimmer,
            audioConcatenator: audioConcatenator,
            folderPath: folderPath,
            resuming: resuming
        )
        model.onBackgroundAudioResave = { Task { await feed.reload() } }
        return model
    }

    var body: some View {
        let container = StreamContainer.decide(horizontalSizeClass: horizontalSizeClass)
        return Group {
            switch container {
            case .split:
                splitView
            case .stack:
                compactStack
            }
        }
        .fullScreenCover(isPresented: showDictation) {
            DictationView(
                model: makeDictationModel(
                    recordsAudio: settingsStore.audioRetention.recordsAudio,
                    audioTrimmer: makeAudioTrimmer(),
                    // File the new thought per the placement captured in `startNewThought` (spec 0026):
                    // inside a user folder -> that folder; from top level / All / Recents -> uncategorized.
                    folderPath: newThoughtFolderPath
                )
            ) { savedThought in
                if let savedThought {
                    Task { await feed.reload() }
                    landOnThought(savedThought)
                }
            }
        }
        .fullScreenCover(item: $resumeThought) { thought in
            DictationView(
                model: makeDictationModel(
                    recordsAudio: settingsStore.audioRetention.recordsAudio,
                    audioTrimmer: makeAudioTrimmer(),
                    audioConcatenator: makeAudioConcatenator(for: thought),
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
        .background(
            UndoManagerHost(
                onManager: { manager in
                    guard !undoManagerInjected else { return }
                    undoManagerInjected = true
                    deletion.undoManager = manager
                },
                reclaimTrigger: undoReclaimTrigger,
                pendingDelete: deletion.pending != nil
            )
        )
        .onChange(of: selectedSubject) { _, _ in undoReclaimTrigger += 1 }
        .onChange(of: selectedRoute) { _, _ in undoReclaimTrigger += 1 }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active { Task { await deletion.commitWindow() } }
        }
        .onChange(of: sortOrder) { _, newValue in settingsStore.thoughtSortOrder = newValue }
        .task {
            await withTaskCancellationHandler {
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

    // MARK: - Compact container (NavigationStack)

    /// The COMPACT-width container (spec 0022 + 0026): the single `NavigationStack` rooted at the top-level
    /// folders screen, with destinations for a user folder / alias (a flat thought list) and a thought /
    /// new-thought (the detail). Each folder screen owns its own bottom bar. The title is the first
    /// scrolling row of each list (spec 0026), so no fixed `.streamListTitle` is applied here.
    private var compactStack: some View {
        NavigationStack(path: $path) {
            TopLevelFoldersView(
                feed: feed,
                sortOrder: $sortOrder,
                searchQuery: $searchQuery,
                playbackController: playbackController,
                onOpenFolder: { name in path.append(.folder([name])) },
                onOpenAlias: { alias in path.append(.alias(alias)) },
                onOpenThought: { thought in path.append(.thought(thought)) },
                onNewKeyboardThought: { folderPath in path.append(.newThought(makeNewThought(in: folderPath))) },
                onNewThought: { folderPath in startNewThought(in: folderPath) },
                onOpenSettings: { showSettings = true },
                onDeleteThought: { id in Task { await deletion.delete(id: id) } },
                deletion: deletion,
                showsBottomBar: StreamContainer.stack.folderScreenShowsOwnBottomBar
            )
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: StreamRoute.self) { route in
                compactDestination(for: route)
            }
        }
    }

    /// The compact stack's destination for a route: a flat thought list for a folder / alias, or the shared
    /// thought detail.
    @ViewBuilder
    private func compactDestination(for route: StreamRoute) -> some View {
        switch route {
        case let .folder(folderPath):
            folderThoughts(subject: .userFolder(folderPath.last ?? ""), showsBottomBar: true, resolved: nil)
                .navigationBarTitleDisplayMode(.inline)
        case let .alias(alias):
            folderThoughts(subject: .alias(alias), showsBottomBar: true, resolved: nil)
                .navigationBarTitleDisplayMode(.inline)
        default:
            detailView(
                for: route,
                onPopThought: { if case .thought = path.last { path.removeLast() } },
                onPopNewThought: { if case .newThought = path.last { path.removeLast() } }
            )
        }
    }

    /// One flat thought list (a user folder or an alias), wired to the active container's navigation.
    private func folderThoughts(
        subject: FolderSubject,
        showsBottomBar: Bool,
        resolved: StreamSearchProjection.Result?
    ) -> some View {
        FolderThoughtsView(
            feed: feed,
            subject: subject,
            sortOrder: $sortOrder,
            searchQuery: $searchQuery,
            playbackController: playbackController,
            onOpenThought: { thought in openThought(thought) },
            onNewKeyboardThought: { folderPath in openNewKeyboardThought(in: folderPath) },
            onNewThought: { folderPath in startNewThought(in: folderPath) },
            onOpenSettings: { showSettings = true },
            onDeleteThought: { id in deleteThought(id) },
            deletion: deletion,
            showsBottomBar: showsBottomBar,
            resolvedContent: resolved
        )
    }

    /// Open a thought in whichever container is active (compact pushes, split selects in the detail column).
    private func openThought(_ thought: Thought) {
        let container = StreamContainer.decide(horizontalSizeClass: horizontalSizeClass)
        switch container {
        case .stack: path.append(.thought(thought))
        case .split: selectedRoute = .thought(thought)
        }
    }

    private func openNewKeyboardThought(in folderPath: [String]) {
        let container = StreamContainer.decide(horizontalSizeClass: horizontalSizeClass)
        switch container {
        case .stack: path.append(.newThought(makeNewThought(in: folderPath)))
        case .split: selectedRoute = .newThought(makeNewThought(in: folderPath))
        }
    }

    private func deleteThought(_ id: UUID) {
        let container = StreamContainer.decide(horizontalSizeClass: horizontalSizeClass)
        switch container {
        case .stack:
            Task { await deletion.delete(id: id) }
        case .split:
            deleteThoughtFromSplit(id)
        }
    }

    // MARK: - Split container (NavigationSplitView) - iPad / regular width

    /// The REGULAR-width container (spec 0022 + 0026): a `NavigationSplitView` - the top-level folders in the
    /// SIDEBAR, the selected folder / alias's flat thought list in the CONTENT column, and the selected
    /// thought in the DETAIL column. The bottom bar + search + undo chip are LIFTED above the columns into
    /// ONE shared surface; both folder columns render without their own bottom bar and share the ONE search
    /// projection.
    private var splitView: some View {
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
        .safeAreaInset(edge: .bottom) {
            liftedBottomStack(state: projection.state)
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// The split-view SIDEBAR: the top-level folders screen. A folder / alias tap selects the subject (the
    /// content column shows its thoughts); a search-result thought tap routes it to the detail column. During
    /// an active search the sidebar keeps its NORMAL folder tree (via `sidebarProjection`).
    private func splitSidebar(projection: StreamSearchProjection.Result) -> some View {
        TopLevelFoldersView(
            feed: feed,
            sortOrder: $sortOrder,
            searchQuery: $searchQuery,
            playbackController: playbackController,
            onOpenFolder: { name in selectSubject(.userFolder(name)) },
            onOpenAlias: { alias in selectSubject(.alias(alias)) },
            onOpenThought: { thought in selectedRoute = .thought(thought) },
            onNewKeyboardThought: { folderPath in selectedRoute = .newThought(makeNewThought(in: folderPath)) },
            onNewThought: { folderPath in startNewThought(in: folderPath) },
            onOpenSettings: { showSettings = true },
            onDeleteThought: { id in deleteThoughtFromSplit(id) },
            deletion: deletion,
            showsBottomBar: StreamContainer.split.folderScreenShowsOwnBottomBar,
            resolvedContent: StreamSearchProjection.sidebarProjection(from: projection),
            onFoldersLoaded: { folderNames in reconcileSplitContent(folderNames: folderNames) }
        )
    }

    /// The split-view CONTENT column: the selected folder / alias's flat thought list, or a placeholder when
    /// nothing is selected. Renders no bottom bar - the lifted stack owns it.
    @ViewBuilder
    private func splitContent(projection: StreamSearchProjection.Result) -> some View {
        if let selectedSubject {
            folderThoughts(
                subject: selectedSubject,
                showsBottomBar: StreamContainer.split.folderScreenShowsOwnBottomBar,
                resolved: projection
            )
        } else {
            SplitContentPlaceholder()
        }
    }

    @ViewBuilder
    private var splitDetail: some View {
        if let selectedRoute {
            NavigationStack {
                detailView(
                    for: selectedRoute,
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

    @ViewBuilder
    private func detailView(
        for route: StreamRoute,
        showsDetailSearch: Bool = true,
        onPopThought: @escaping () -> Void,
        onPopNewThought: @escaping () -> Void
    ) -> some View {
        let enablesFind = showsDetailSearch
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
                    onPopThought()
                    Task { await deletion.delete(id: id) }
                },
                enablesFind: enablesFind,
                resumeApplies: resumeApplies(for: thought)
            )
        case let .newThought(thought):
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
                enablesFind: enablesFind,
                startInEdit: true
            )
        case .folder, .alias:
            // A folder / alias route is never a detail; the folder columns handle it.
            EmptyView()
        }
    }

    /// The LIFTED bottom stack for the split view (spec 0022): the ONE search field + record/new-thought
    /// actions, the now-playing bar, and the undo-delete chip, above BOTH columns. The record/new-thought
    /// actions file per the placement of the currently-selected subject (spec 0026): a user folder ->
    /// contextual, an alias / no selection -> uncategorized.
    private func liftedBottomStack(state screenState: FolderScreenState) -> some View {
        StreamBottomStack(
            query: $searchQuery,
            screenState: screenState,
            deletion: deletion,
            playbackController: playbackController,
            onOpenThought: { selectedRoute = .thought($0) },
            onNewKeyboardThought: { selectedRoute = .newThought(makeNewThought(in: liftedPlacement)) },
            onNewThought: { startNewThought(in: liftedPlacement) }
        )
        .padding(.horizontal, CanopySpacing.x4)
    }

    /// The new-thought placement for the lifted split bar (spec 0026): the currently-selected subject decides
    /// - a user folder files contextually, an alias or no selection files uncategorized.
    private var liftedPlacement: [String] {
        // No selection files uncategorized, like an alias; otherwise defer to the pure placement decision.
        guard let selectedSubject else { return NewThoughtPlacement.folderPath(browsingFolder: []) }
        return NewThoughtPlacement.folderPath(for: selectedSubject)
    }

    private func deleteThoughtFromSplit(_ id: UUID) {
        if SplitDetailReconcile.deleteClearsSelection(deletedId: id, shownThoughtId: selectedThoughtId) {
            selectedRoute = nil
        }
        Task { await deletion.delete(id: id) }
    }

    private var selectedThoughtId: UUID? {
        if case let .thought(thought) = selectedRoute { return thought.id }
        return nil
    }

    /// Select a subject (a user folder or an alias) in the split view's sidebar: point the content column at
    /// it and clear the detail column (the previously-open thought belonged to the old context).
    private func selectSubject(_ subject: FolderSubject) {
        selectedSubject = subject
        selectedRoute = nil
    }

    /// Reconcile the split view's CONTENT column after the sidebar's folder names reload (spec 0026): if the
    /// user folder shown in the content column was renamed or deleted from the sidebar, its subject no longer
    /// exists, so the content column would silently show an empty list. Clearing `selectedSubject` reverts it
    /// to the placeholder (and clears any detail selection). Alias subjects always survive. Also gates the
    /// lifted projection (`splitFoldersLoaded`) like the compact `folderLoaded` gate. The pure decision is
    /// `SplitDetailReconcile.contentSubjectSurvives`.
    private func reconcileSplitContent(folderNames: [String]) {
        splitFoldersLoaded = true
        if !SplitDetailReconcile.contentSubjectSurvives(selectedSubject, inFolderNames: folderNames) {
            selectedSubject = nil
            selectedRoute = nil
        }
    }

    /// Land on a just-saved thought from a dictation / resume session, in whichever container is active. A
    /// fresh recording is uncategorized (root) unless it was filed in a folder; the split view points the
    /// sidebar at the matching subject (its top-level folder, or All Thoughts for an uncategorized thought).
    private func landOnThought(_ thought: Thought) {
        let container = StreamContainer.decide(horizontalSizeClass: horizontalSizeClass)
        switch container {
        case .stack:
            path = [.thought(thought)]
        case .split:
            if let folder = thought.folderPath.first {
                selectSubject(.userFolder(folder))
            } else {
                selectSubject(.alias(.allThoughts))
            }
            selectedRoute = .thought(thought)
        }
    }
}

/// The split-view CONTENT-column placeholder shown before a folder / alias is selected (spec 0026): a
/// centered prompt sized for a wide canvas.
struct SplitContentPlaceholder: View {
    var body: some View {
        VStack(spacing: CanopySpacing.x3) {
            Image(systemName: "folder")
                .font(.system(size: CanopyFont.sizeX4xl, weight: .semibold))
                .foregroundStyle(CanopyColor.primary)
            Text("Pick a folder")
                .font(.system(size: CanopyFont.sizeXl, weight: .semibold))
                .foregroundStyle(CanopyColor.text)
            Text("Choose All Thoughts, Recents, or a folder to see its thoughts.")
                .font(.system(size: CanopyFont.sizeSm))
                .foregroundStyle(CanopyColor.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CanopySpacing.x8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CanopyColor.bg.ignoresSafeArea())
    }
}

/// The split-view detail-column placeholder shown when no thought is selected (spec 0022): a centered
/// waveform + prompt, sized for a wide canvas.
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
