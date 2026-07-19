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
            .task(id: feed.reloadGeneration) {
                await reloadFolders()
            }
    }

    @ViewBuilder
    private func switchingContent(state screenState: FolderScreenState, results searchResults: [Thought]) -> some View {
        switch screenState {
        case .emptyStore:
            FolderEmptyStateCTA(
                isRoot: true,
                onRecord: { onNewThought(topLevelPlacement) },
                onNewKeyboardThought: { onNewKeyboardThought(topLevelPlacement) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .searchResults:
            searchResultsList(searchResults)
        case .noMatches:
            NoSearchMatchesState(query: searchQuery)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .normal:
            foldersList
        }
    }

    // MARK: - Lists

    /// The top-level folder list (spec 0026): the title header row, the two pinned alias rows, then the user
    /// folders. FOLDERS ONLY - no thoughts.
    private var foldersList: some View {
        // Bucket every folder's flattened thought count in ONE pass (spec 0026) so the rows do not each
        // rescan the whole thoughts array (O(thoughts) here, not O(folders x thoughts) per render).
        let counts = TopLevelFolders.folderThoughtCounts(feed.thoughts)
        return List {
            StreamListTitleRow(title: "Thoughts")

            ForEach(AliasFolder.allCases) { alias in
                aliasRow(alias)
            }

            ForEach(userFolders, id: \.self) { name in
                folderRow(name: name, count: counts[name] ?? 0)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func searchResultsList(_ results: [Thought]) -> some View {
        List {
            ForEach(results) { thought in
                Button {
                    onOpenThought(thought)
                } label: {
                    ThoughtCard(thought: thought)
                }
                .buttonStyle(.plain)
                .tightRowInsets()
                .contextMenu {
                    ThoughtActionsMenu(thought: thought, onCopied: { copiedTrigger += 1 }) {
                        Button {
                            moveThought = thought
                        } label: {
                            Label("Move to folder", systemImage: "folder")
                        }
                        Button(role: .destructive) {
                            onDeleteThought(thought.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        onDeleteThought(thought.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// A pinned virtual alias folder row (All Thoughts / Recents), visually distinct from a user folder (a
    /// tinted glyph, no context menu, no count) and not renamable/deletable.
    private func aliasRow(_ alias: AliasFolder) -> some View {
        Button {
            onOpenAlias(alias)
        } label: {
            AliasFolderRow(alias: alias)
        }
        .buttonStyle(.plain)
        .tightRowInsets()
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
        Button {
            onOpenFolder(name)
        } label: {
            FolderRow(
                name: name,
                countLabel: TopLevelFolders.thoughtCountLabel(count)
            )
        }
        .buttonStyle(.plain)
        .tightRowInsets()
        .contextMenu {
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
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(ThoughtSortOrder.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .tint(CanopyColor.primary)
        }
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
                Button("Rename") { Task { await renameFolder() } }
                Button("Cancel", role: .cancel) { activeDialog = nil }
            }
    }

    private var deleteFolderAlertAnchor: some View {
        Color.clear
            .alert("Delete folder?", isPresented: dialogBinding { $0.isDeleteFolder }) {
                Button("Delete", role: .destructive) { Task { await deleteFolder() } }
                Button("Cancel", role: .cancel) { activeDialog = nil }
            } message: {
                Text("This deletes the folder and everything inside it - thoughts, recordings, and subfolders. This can't be undone.")
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

    private func renameFolder() async {
        guard case let .renameFolder(path, _)? = activeDialog else { return }
        let newName = folderNameField
        activeDialog = nil
        let renamed = await feed.renameFolder(at: path, to: newName)
        await reloadFolders()
        if renamed == nil {
            folderError = "Couldn't rename - the name is invalid or already used."
        }
    }

    private func deleteFolder() async {
        guard case let .deleteFolder(path)? = activeDialog else { return }
        activeDialog = nil
        await feed.deleteFolder(at: path)
        await reloadFolders()
    }
}

/// A pinned virtual alias folder row (spec 0026): a tinted glyph, the alias title, and a chevron - visually
/// distinct from a user `FolderRow` (no count, filled tinted icon background) so All Thoughts / Recents read
/// as smart folders. No rename/delete affordance.
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
        .background(CanopyColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: CanopyRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CanopyRadius.lg, style: .continuous)
                .stroke(CanopyColor.border, lineWidth: 1)
        )
    }
}
