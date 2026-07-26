import SwiftUI

/// The redesigned top-level Thoughts screen (spec 0026): FOLDERS ONLY. It shows two pinned virtual alias
/// folders - All Thoughts and Recents - then the user's folders, and NO loose thoughts and NO interleaving.
/// There is no sub-folder creation (one level deep); the new-folder button and move-to-folder target the
/// top level.
///
/// The screen TITLE ("Thoughts") is the FIRST element of the scrollable list (a header row that scrolls
/// away), not a fixed below-the-toolbar title (spec 0026). The persistent bottom bar + global search (spec
/// 0021) and the search-focus-stability fix (feedback 0024) are preserved: the bottom stack hangs off the
/// STABLE outer node, and only the list content switches on state. A global search here shows a flat
/// results list of matching thoughts (search reaches every thought, including uncategorized ones).
struct TopLevelFoldersView: View {
    @ObservedObject var feed: StreamFeed
    @Binding var sortOrder: ThoughtSortOrder
    @Binding var searchQuery: String
    let playbackController: ThoughtPlaybackController?

    /// Open a user folder (by name, one level).
    let onOpenFolder: (String) -> Void
    /// Open a virtual alias folder (All Thoughts / Recents).
    let onOpenAlias: (AliasFolder) -> Void
    /// Open a thought (from a global search result row).
    let onOpenThought: (Thought) -> Void
    /// Create a blank keyboard thought. From the top level a new thought is UNCATEGORIZED (`[]`).
    let onNewKeyboardThought: ([String]) -> Void
    /// Start a new dictation session. From the top level it is UNCATEGORIZED (`[]`).
    let onNewThought: ([String]) -> Void
    let onOpenSettings: () -> Void
    let onDeleteThought: (UUID) -> Void
    @ObservedObject var deletion: ThoughtDeletionController

    var showsBottomBar: Bool = true
    var resolvedContent: StreamSearchProjection.Result?
    /// Fired whenever the top-level folder names (re)load, carrying the loaded names (spec 0022 gate parity
    /// for the split view, plus spec 0026 content-column reconcile so a rename/delete of the shown folder in
    /// the sidebar can revert the content column to its placeholder). Fires on EVERY reload, not just the
    /// first, so the split view learns of a rename/delete.
    var onFoldersLoaded: (([String]) -> Void)?

    @State private var childFolderNames: [String] = []
    @State private var folderLoaded = false

    @State private var activeDialog: FolderDialog?
    @State private var folderNameField = ""
    @State private var folderError: String?

    @State private var moveThought: Thought?
    /// The folder to move existing thoughts INTO (feedback 0029, item 4b): a folder-row "Move thoughts here"
    /// action opens the multi-select picker for THIS folder. Nil dismisses it.
    @State private var moveIntoFolder: String?
    @State private var copiedTrigger = 0
    @State private var showCopiedConfirmation = false

    /// New thoughts from the top level are uncategorized (spec 0026).
    private var topLevelPlacement: [String] { NewThoughtPlacement.folderPath(browsingFolder: []) }

    /// The user folders, A-Z (the alias folders are rendered separately, pinned first).
    private var userFolders: [String] {
        TopLevelFolders.userFolderNames(childFolderNames: childFolderNames)
    }

    private func resolveContent() -> StreamSearchProjection.Result {
        if let resolvedContent { return resolvedContent }
        return StreamSearchProjection.resolve(
            didLoad: feed.didLoad && folderLoaded,
            thoughts: feed.thoughts,
            searchQuery: searchQuery
        )
    }

    var body: some View {
        let content = resolveContent()
        return bodyContent(state: content.state, results: content.results)
    }

    @ViewBuilder
    private func bodyContent(state screenState: FolderScreenState, results searchResults: [Thought]) -> some View {
        switchingContent(state: screenState, results: searchResults)
            .id("stream-top-level-content")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CanopyColor.bg.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                if showsBottomBar {
                    StreamBottomStack(
                        query: $searchQuery,
                        screenState: screenState,
                        deletion: deletion,
                        playbackController: playbackController,
                        onOpenThought: onOpenThought,
                        onNewKeyboardThought: { onNewKeyboardThought(topLevelPlacement) },
                        onNewThought: { onNewThought(topLevelPlacement) }
                    )
                    // Pin a STABLE identity on the bottom stack (feedback 0026, item 3): when the primary
                    // content swaps one List for another on the first keystroke (normal -> searchResults),
                    // the `.safeAreaInset` re-lays-out; without a fixed id SwiftUI can rebuild the stack's
                    // search `TextField` and drop first responder, so the field lost focus after one letter.
                    // A constant id keeps the field the SAME instance across every content-state flip.
                    .id("stream-bottom-stack")
                }
            }
            .overlay(alignment: .top) {
                if feed.deleteFailed {
                    DeleteFailedBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task {
                            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                            feed.clearDeleteFailure()
                        }
                } else if let folderError {
                    FolderErrorBanner(message: folderError)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task {
                            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                            self.folderError = nil
                        }
                }
            }
            .copiedConfirmation(trigger: copiedTrigger, isShown: $showCopiedConfirmation, alignment: .top)
            .animation(.easeInOut(duration: 0.2), value: feed.deleteFailed)
            .animation(.easeInOut(duration: 0.2), value: folderError)
            .toolbar { toolbarContent }
            .background(newFolderAlertAnchor)
            .background(renameFolderAlertAnchor)
            .background(deleteFolderAlertAnchor)
            .sheet(item: $moveThought) { thought in
                MoveToFolderSheet(
                    thought: thought,
                    childFolders: { await feed.childFolders(at: $0) },
                    createFolder: { name, path in await feed.createFolder(named: name, at: path) },
                    onMove: { folderPath in
                        await feed.move(thought, to: folderPath)
                        await reloadFolders()
                    }
                )
            }
            // Move existing thoughts INTO a folder from a folder row (feedback 0029, item 4b): the SAME
            // multi-select picker + batch move path the folder screen's "..." menu and the empty-state CTA
            // use, so there is one drawer and one move path.
            .sheet(item: moveIntoFolderBinding) { target in
                MoveThoughtsIntoFolderSheet(
                    folderName: target.name,
                    allThoughts: feed.thoughts,
                    onMove: { ids in
                        let toMove = feed.thoughts.filter { ids.contains($0.id) }
                        await feed.move(toMove, to: [target.name])
                        await reloadFolders()
                    }
                )
            }
            .task(id: feed.reloadGeneration) {
                await reloadFolders()
            }
    }

    @ViewBuilder
    private func switchingContent(state screenState: FolderScreenState, results searchResults: [Thought]) -> some View {
        // ONE persistent List for the normal / results / no-matches states so the search field's host is
        // never torn down mid-typing (feedback 0029, item 8): only the List's ROWS change with the query, so
        // SwiftUI diffs cells in place rather than swapping one List view for a different one (the identity
        // churn that resigned the field's first responder). The empty-store state has no search field, so it
        // is a separate centered CTA - the only transition off the shared List happens when the store goes
        // from zero thoughts to some, never mid-typing. `FolderScreenState.contentUsesList` pins which states
        // share the list.
        if screenState.contentUsesList {
            unifiedContentList(state: screenState, results: searchResults)
        } else {
            FolderEmptyStateCTA(
                isRoot: true,
                onRecord: { onNewThought(topLevelPlacement) },
                onNewKeyboardThought: { onNewKeyboardThought(topLevelPlacement) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Lists

    /// The ONE persistent list hosting the normal folder list, the global search results, or the no-matches
    /// message (feedback 0029, item 8). It is a single `List` instance across those states - the ROWS differ
    /// by state, the List node does not - so the `.safeAreaInset` search field above never re-mounts.
    @ViewBuilder
    private func unifiedContentList(state screenState: FolderScreenState, results searchResults: [Thought]) -> some View {
        // Bucket every folder's flattened thought count in ONE pass (spec 0026) so the rows do not each
        // rescan the whole thoughts array (O(thoughts) here, not O(folders x thoughts) per render).
        let counts = TopLevelFolders.folderThoughtCounts(feed.thoughts)
        List {
            switch screenState {
            case .normal:
                // The title sits ABOVE the unified card (Notes-app style), as its own chrome-free header row
                // so the grouped container below holds ONLY the folder rows (feedback 0025).
                StreamListTitleRow(title: "Thoughts")
                // The alias + user folders form ONE unified inset card (feedback 0025).
                Section {
                    ForEach(AliasFolder.allCases) { alias in
                        aliasRow(alias)
                    }
                    ForEach(userFolders, id: \.self) { name in
                        folderRow(name: name, count: counts[name] ?? 0)
                    }
                }
            case .searchResults:
                // The global results form ONE unified inset card too (feedback 0025), so a search reads the
                // same grouped way as a folder list.
                Section {
                    ForEach(searchResults) { thought in
                        // The SAME shared row the folder screen uses (spec 0026, architect review), so a
                        // global search result is identical everywhere - it keeps its play/move leading swipe.
                        ThoughtResultRow(
                            thought: thought,
                            playbackController: playbackController,
                            onOpen: onOpenThought,
                            onMove: { moveThought = $0 },
                            onDelete: onDeleteThought,
                            onCopied: { copiedTrigger += 1 }
                        )
                    }
                }
            case .noMatches:
                // A single no-matches row INSIDE the same list, so the list host (and the search field above
                // it) is not torn down when a query stops matching (feedback 0029, item 8).
                NoMatchesRow(query: searchQuery)
            case .emptyStore:
                // Never reached: emptyStore does not use the list (see switchingContent).
                EmptyView()
            }
        }
        .unifiedList()
    }

    /// A pinned virtual alias folder row (All Thoughts / Recents), visually distinct from a user folder (a
    /// tinted glyph, no context menu, no count) and not renamable/deletable.
    private func aliasRow(_ alias: AliasFolder) -> some View {
        AliasFolderRow(alias: alias)
            .contentShape(Rectangle())
            .onTapGesture { onOpenAlias(alias) }
            .accessibilityAddTraits(.isButton)
            .unifiedRow()
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            // A leading swipe on an alias plays its recordings as a queue (parity with the old folder swipe).
            if let controller = playbackController {
                Button {
                    controller.playQueue(aliasQueue(alias))
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .tint(CanopyColor.success)
            }
        }
    }

    private func folderRow(name: String, count: Int) -> some View {
        FolderRow(
            name: name,
            countLabel: TopLevelFolders.thoughtCountLabel(count)
        )
            .contentShape(Rectangle())
            .onTapGesture { onOpenFolder(name) }
            .accessibilityAddTraits(.isButton)
            .unifiedRow()
        .contextMenu {
            // "Move thoughts here" sits beside Rename (feedback 0029, item 4b), opening the multi-select
            // picker for this folder - the same batch-move path the folder screen's "..." menu uses.
            Button {
                moveIntoFolder = name
            } label: {
                Label("Move thoughts here", systemImage: "folder")
            }
            Button {
                beginRename(name: name)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                activeDialog = .deleteFolder(path: [name])
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if let controller = playbackController {
                Button {
                    controller.playQueue(folderQueue(name))
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .tint(CanopyColor.success)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                activeDialog = .deleteFolder(path: [name])
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                beginRename(name: name)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(CanopyColor.primary)
            // "Move thoughts here" beside Rename on the trailing swipe (feedback 0029, item 4b).
            Button {
                moveIntoFolder = name
            } label: {
                Label("Move here", systemImage: "folder")
            }
            .tint(CanopyColor.success)
        }
    }

    /// The recorded thoughts of a user folder, in sort order, for a folder-swipe play queue.
    private func folderQueue(_ name: String) -> [Thought] {
        let inFolder = feed.thoughts.filter { $0.hasAudio && $0.folderPath.first == name }
        return sortOrder.sort(inFolder)
    }

    /// The recorded thoughts an alias projects, for an alias-swipe play queue.
    private func aliasQueue(_ alias: AliasFolder) -> [Thought] {
        switch alias {
        case .allThoughts:
            return TopLevelFolders.allThoughts(feed.thoughts.filter { $0.hasAudio }, sorted: sortOrder)
        case .recents:
            return TopLevelFolders.recents(feed.thoughts.filter { $0.hasAudio })
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                folderNameField = ""
                activeDialog = .newFolder
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .tint(CanopyColor.primary)
        }
        // No sort control here (feedback 0029, item 2): the top level is FOLDERS ONLY (spec 0026) - folders
        // show A-Z and the aliases define their own order, so there is nothing thought-ordered to sort. Sort
        // stays meaningful INSIDE a folder (`FolderThoughtsView`), and `sortOrder` still orders the swipe-to-
        // play queues here, so the binding is kept even though its toolbar affordance is gone.
        ToolbarItem(placement: .topBarTrailing) {
            Button { onOpenSettings() } label: {
                Image(systemName: "gearshape")
            }
            .tint(CanopyColor.primary)
        }
    }

    // MARK: - Folder dialog hosts (spec 0021 rename-bug fix, top-level only)

    private func beginRename(name: String) {
        folderNameField = name
        activeDialog = .renameFolder(path: [name], currentName: name)
    }

    /// An `Identifiable` binding over the `moveIntoFolder` folder name, so `.sheet(item:)` presents the
    /// multi-select picker for that folder (feedback 0029, item 4b).
    private var moveIntoFolderBinding: Binding<MoveIntoFolderTarget?> {
        Binding(
            get: { moveIntoFolder.map(MoveIntoFolderTarget.init(name:)) },
            set: { moveIntoFolder = $0?.name }
        )
    }

    private func dialogBinding(for match: @escaping (FolderDialog) -> Bool) -> Binding<Bool> {
        Binding(
            get: { activeDialog.map(match) ?? false },
            set: { presented in if !presented, let d = activeDialog, match(d) { activeDialog = nil } }
        )
    }

    private var newFolderAlertAnchor: some View {
        Color.clear
            .alert("New folder", isPresented: dialogBinding { $0.isNewFolder }) {
                folderNameTextField(placeholder: "Name")
                Button("Create") { Task { await createFolder() } }
                Button("Cancel", role: .cancel) { activeDialog = nil }
            } message: {
                Text("Create a folder at the top level.")
            }
    }

    private var renameFolderAlertAnchor: some View {
        Color.clear
            .alert("Rename folder", isPresented: dialogBinding { $0.isRenameFolder }) {
                folderNameTextField(placeholder: "Name")
                Button("Rename") {
                    // Capture the payload SYNCHRONOUSLY through the pure `FolderDialogAction.capture` seam
                    // (feedback 0026, item 4): tapping an alert button dismisses the alert, which fires the
                    // dialog binding and clears `activeDialog`. A deferred `Task` that read `activeDialog`
                    // ran AFTER that clear and saw nil, so the rename silently did nothing. Capture now.
                    performCaptured(FolderDialogAction.capture(from: activeDialog, name: folderNameField))
                }
                Button("Cancel", role: .cancel) { activeDialog = nil }
            }
    }

    private var deleteFolderAlertAnchor: some View {
        Color.clear
            .alert("Delete folder?", isPresented: dialogBinding { $0.isDeleteFolder }) {
                Button("Delete", role: .destructive) {
                    // Capture synchronously, same reason as rename above (feedback 0026, item 4).
                    performCaptured(FolderDialogAction.capture(from: activeDialog, name: folderNameField))
                }
                Button("Cancel", role: .cancel) { activeDialog = nil }
            } message: {
                Text("This deletes the folder and everything inside it - its thoughts and their recordings. This can't be undone.")
            }
    }

    private func folderNameTextField(placeholder: String) -> some View {
        TextField(placeholder, text: $folderNameField)
    }

    // MARK: - Actions

    private func reloadFolders() async {
        childFolderNames = await feed.childFolders(at: [])
        folderLoaded = true
        onFoldersLoaded?(childFolderNames)
    }

    private func createFolder() async {
        let name = folderNameField
        activeDialog = nil
        let created = await feed.createFolder(named: name, at: [])
        await reloadFolders()
        if created == nil {
            folderError = "That name can't be used. Try another."
        }
    }

    /// Dispatch a captured folder action (feedback 0026, item 4). The payload was read synchronously at tap
    /// time via `FolderDialogAction.capture`, so it is independent of `activeDialog`, which the alert's
    /// dismissal will clear before this async work runs.
    private func performCaptured(_ action: FolderDialogAction?) {
        guard let action else { return }
        Task {
            switch action {
            case let .rename(path, newName):
                await renameFolder(at: path, to: newName)
            case let .delete(path):
                await deleteFolder(at: path)
            }
        }
    }

    private func renameFolder(at path: [String], to newName: String) async {
        activeDialog = nil
        let renamed = await feed.renameFolder(at: path, to: newName)
        await reloadFolders()
        if renamed == nil {
            folderError = "Couldn't rename - the name is invalid or already used."
        }
    }

    private func deleteFolder(at path: [String]) async {
        activeDialog = nil
        await feed.deleteFolder(at: path)
        await reloadFolders()
    }
}

/// A folder name wrapped as `Identifiable` so a folder-row "Move thoughts here" action can drive a
/// `.sheet(item:)` (feedback 0029, item 4b). The name is its identity - one drawer per folder.
private struct MoveIntoFolderTarget: Identifiable {
    let name: String
    var id: String { name }
}

/// A pinned virtual alias folder row (spec 0026): a tinted glyph, the alias title, and a chevron - visually
/// distinct from a user `FolderRow` (no count, filled tinted icon background) so All Thoughts / Recents read
/// as smart folders. No rename/delete affordance.
///
/// Feedback 0025 (unified list): the surface / border / rounded-corner chrome moved off this row onto the
/// whole list container (Notes-app-style grouped list), so only the row CONTENT lives here now.
struct AliasFolderRow: View {
    let alias: AliasFolder

    var body: some View {
        HStack(spacing: CanopySpacing.x3) {
            Image(systemName: alias.systemImage)
                .font(.system(size: CanopyFont.sizeBase, weight: .semibold))
                .foregroundStyle(CanopyColor.primaryForeground)
                .frame(width: CanopySpacing.x8, height: CanopySpacing.x8)
                .background(CanopyColor.primary)
                .clipShape(RoundedRectangle(cornerRadius: CanopyRadius.md, style: .continuous))

            Text(alias.title)
                .font(.system(size: CanopyFont.sizeLg, weight: .semibold))
                .foregroundStyle(CanopyColor.text)
                .lineLimit(1)

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: CanopyFont.sizeSm, weight: .semibold))
                .foregroundStyle(CanopyColor.textSubtle)
        }
        .padding(CanopySpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
