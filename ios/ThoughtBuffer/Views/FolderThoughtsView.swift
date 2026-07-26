import SwiftUI

/// The flat thought list for a user folder OR a virtual alias folder (spec 0026). A user folder shows its
/// thoughts flattened over any legacy nested subtree; an alias shows a pure projection (All Thoughts = every
/// thought sorted; Recents = the 10 most recent, newest first). There is no interleaving and no nesting -
/// only thoughts, one level deep.
///
/// The screen TITLE (the folder name / "All Thoughts" / "Recents") is the FIRST element of the scrollable
/// list (a header row that scrolls away), not a fixed below-the-toolbar title (spec 0026). The persistent
/// bottom bar + search (spec 0021) and the search-focus-stability fix (feedback 0024) are preserved: the
/// bottom stack hangs off the STABLE outer node, and only the list content switches on state.
struct FolderThoughtsView: View {
    @ObservedObject var feed: StreamFeed

    /// What this screen shows: a user folder (by name) or a virtual alias (the pure `FolderSubject`). Drives
    /// the title, the thought projection, and whether new-thought placement is contextual (a user folder) or
    /// uncategorized (an alias).
    let subject: FolderSubject
    @Binding var sortOrder: ThoughtSortOrder
    @Binding var searchQuery: String
    let playbackController: ThoughtPlaybackController?

    let onOpenThought: (Thought) -> Void
    /// Create a blank keyboard thought filed per this screen's placement (spec 0026): a user folder -> that
    /// folder, an alias -> uncategorized.
    let onNewKeyboardThought: ([String]) -> Void
    /// Start a new dictation session, filed per this screen's placement (contextual for a user folder,
    /// uncategorized for an alias).
    let onNewThought: ([String]) -> Void
    let onOpenSettings: () -> Void
    let onDeleteThought: (UUID) -> Void
    @ObservedObject var deletion: ThoughtDeletionController

    /// Rename this (user) folder from the nav-bar "..." menu (feedback 0026, item 5): the root renames it
    /// through the store and re-points navigation at the new name. Nil on an alias screen (no rename).
    var onRenameFolder: ((_ path: [String], _ newName: String) -> Void)?
    /// Delete this (user) folder from the nav-bar "..." menu (feedback 0026, item 5): the root deletes it
    /// through the store (a cascade) and pops back to the top-level screen. Nil on an alias screen.
    var onDeleteFolder: ((_ path: [String]) -> Void)?

    /// Whether this screen renders its own bottom stack (compact stack: true; split columns: false, the
    /// stack is lifted). Same contract as the retired interleaving screen.
    var showsBottomBar: Bool = true
    /// A pre-resolved search projection injected by the split container so the columns share ONE scan.
    var resolvedContent: StreamSearchProjection.Result?

    @State private var moveThought: Thought?
    @State private var copiedTrigger = 0
    @State private var showCopiedConfirmation = false
    /// Presents the multi-select "move thoughts into this folder" picker (feedback 0026, item 6).
    @State private var showMoveIntoFolder = false

    /// The active folder dialog (rename / delete) from the "..." menu (feedback 0026, item 5). One enum
    /// state hosts both alerts, matching `TopLevelFoldersView`'s pattern (feedback 0018 un-stacked alerts).
    @State private var activeDialog: FolderDialog?
    @State private var folderNameField = ""

    /// The name of the user folder shown, or nil on an alias (aliases cannot be renamed/deleted).
    private var userFolderName: String? {
        if case let .userFolder(name) = subject { return name }
        return nil
    }

    /// The placement `folderPath` for a new thought created on this screen (spec 0026), from the pure
    /// `NewThoughtPlacement`: a user folder files contextually into `[name]`; an alias files uncategorized.
    private var newThoughtFolderPath: [String] {
        NewThoughtPlacement.folderPath(for: subject)
    }

    /// The thoughts shown, projected purely from the loaded list per the subject and sort order.
    private var thoughts: [Thought] {
        TopLevelFolders.thoughts(feed.thoughts, for: subject, sorted: sortOrder)
    }

    private func resolveContent() -> StreamSearchProjection.Result {
        if let resolvedContent { return resolvedContent }
        return StreamSearchProjection.resolve(
            didLoad: feed.didLoad,
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
        // Keep-search-focus fix (feedback 0024): only the content area switches on `screenState`, hosted on
        // its own stable-identity node, so a state flip never tears down the outer node that carries the
        // bottom bar and its search `TextField`.
        switchingContent(state: screenState, results: searchResults)
            .id("stream-folder-thoughts-content")
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
                        onNewKeyboardThought: { onNewKeyboardThought(newThoughtFolderPath) },
                        onNewThought: { onNewThought(newThoughtFolderPath) }
                    )
                    // Pin a STABLE identity so the search field survives the content-state flip on the first
                    // keystroke (feedback 0026, item 3) - see TopLevelFoldersView for the full rationale.
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
                }
            }
            .copiedConfirmation(trigger: copiedTrigger, isShown: $showCopiedConfirmation, alignment: .top)
            .animation(.easeInOut(duration: 0.2), value: feed.deleteFailed)
            .toolbar { toolbarContent }
            .background(renameFolderAlertAnchor)
            .background(deleteFolderAlertAnchor)
            .sheet(item: $moveThought) { thought in
                MoveToFolderSheet(
                    thought: thought,
                    childFolders: { await feed.childFolders(at: $0) },
                    createFolder: { name, path in await feed.createFolder(named: name, at: path) },
                    onMove: { folderPath in await feed.move(thought, to: folderPath) }
                )
            }
            .sheet(isPresented: $showMoveIntoFolder) {
                if let folderName = userFolderName {
                    MoveThoughtsIntoFolderSheet(
                        folderName: folderName,
                        allThoughts: feed.thoughts,
                        onMove: { ids in await moveIntoFolder(ids: ids, folderName: folderName) }
                    )
                }
            }
    }

    /// Move every selected thought into this folder (feedback 0026, item 6): re-file them all in ONE batch
    /// so the driver reloads once (no per-thought reload flicker).
    private func moveIntoFolder(ids: Set<UUID>, folderName: String) async {
        let toMove = feed.thoughts.filter { ids.contains($0.id) }
        await feed.move(toMove, to: [folderName])
    }

    @ViewBuilder
    private func switchingContent(state screenState: FolderScreenState, results searchResults: [Thought]) -> some View {
        // ONE persistent List for the normal / results / no-matches states so the search field's host is
        // never torn down mid-typing (feedback 0029, item 8): only the List's ROWS change with the query, so
        // SwiftUI diffs cells in place rather than swapping one List view for a different one (the identity
        // churn that resigned the field's first responder). The empty-store state has no search field, so it
        // is a separate centered CTA - the only transition off the shared List happens when the store goes
        // from zero thoughts to some, never mid-typing. `FolderScreenState.contentUsesList` pins which states
        // share the list. NOTE: an empty USER folder's CTA (feedback 0026, item 6) is rendered as a row
        // INSIDE this one list rather than as a separate centered view, so typing to search from an empty
        // folder does not swap the list host either.
        if screenState.contentUsesList {
            unifiedContentList(state: screenState, results: searchResults)
        } else {
            // A truly empty store (no thoughts anywhere): the centered CTA with NO Move action - there is
            // nothing anywhere to move into this folder (feedback 0026, item 6). No search field here.
            FolderEmptyStateCTA(
                isRoot: false,
                onRecord: { onNewThought(newThoughtFolderPath) },
                onNewKeyboardThought: { onNewKeyboardThought(newThoughtFolderPath) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Whether the normal state shows the empty-USER-folder CTA (feedback 0026, item 6): an empty user folder
    /// while the store holds thoughts elsewhere offers Move thoughts here / Record / New. An empty alias keeps
    /// a plain inline message instead (moving into a virtual All/Recents folder is meaningless).
    private var showsEmptyUserFolderCTA: Bool {
        if thoughts.isEmpty, case .userFolder = subject { return true }
        return false
    }

    /// The ONE persistent list hosting the normal thought list, the global search results, or the no-matches
    /// message (feedback 0029, item 8). It is a single `List` instance across those states - the ROWS differ
    /// by state, the List node does not - so the `.safeAreaInset` search field above never re-mounts. The
    /// empty-user-folder CTA is a full-height row inside this same list.
    @ViewBuilder
    private func unifiedContentList(state screenState: FolderScreenState, results searchResults: [Thought]) -> some View {
        List {
            switch screenState {
            case .normal:
                if showsEmptyUserFolderCTA {
                    // The empty-user-folder CTA as a full-height row, so the list host (and the search field
                    // above it) stays put when the user starts typing to search from an empty folder.
                    EmptyUserFolderCTARow(
                        onMoveToFolder: { showMoveIntoFolder = true },
                        onRecord: { onNewThought(newThoughtFolderPath) },
                        onNewKeyboardThought: { onNewKeyboardThought(newThoughtFolderPath) }
                    )
                } else {
                    // The title sits ABOVE the unified card (Notes-app style), as its own chrome-free header
                    // row so the grouped container holds ONLY the thought rows (feedback 0025).
                    StreamListTitleRow(title: subject.title)
                    Section {
                        if thoughts.isEmpty {
                            EmptyFolderRow(subject: subject)
                        }
                        ForEach(thoughts) { thought in
                            thoughtRow(thought: thought)
                        }
                    }
                }
            case .searchResults:
                // The global results form ONE unified inset card too (feedback 0025); no title (the query is
                // the context there).
                Section {
                    ForEach(searchResults) { thought in
                        thoughtRow(thought: thought)
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

    private func thoughtRow(thought: Thought) -> some View {
        // The ONE shared row (spec 0026), so a thought looks and behaves identically in a folder list and in
        // a global search-result list on any screen.
        ThoughtResultRow(
            thought: thought,
            playbackController: playbackController,
            onOpen: onOpenThought,
            onMove: { moveThought = $0 },
            onDelete: onDeleteThought,
            onCopied: { copiedTrigger += 1 }
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
            // Recents is defined as newest-first; the sort menu does not apply there.
            .disabled(isAlias(.recents))
        }
        // A "..." menu to rename or delete THIS folder (feedback 0026, item 5), wired to the same store
        // ops the top-level screen uses. Shown only for a user folder - an alias (All Thoughts / Recents)
        // is a virtual projection and cannot be renamed or deleted.
        if let folderName = userFolderName {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Pull existing thoughts INTO this folder (feedback 0029, item 4a): opens the SAME
                    // multi-select picker + batch-move path the empty-state CTA uses, so a non-empty folder
                    // can still gather thoughts (the empty-state action vanished once the folder had one).
                    Button {
                        showMoveIntoFolder = true
                    } label: {
                        Label("Move thoughts here", systemImage: "folder")
                    }
                    Button {
                        folderNameField = folderName
                        activeDialog = .renameFolder(path: [folderName], currentName: folderName)
                    } label: {
                        Label("Rename folder", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        activeDialog = .deleteFolder(path: [folderName])
                    } label: {
                        Label("Delete folder", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .tint(CanopyColor.primary)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { onOpenSettings() } label: {
                Image(systemName: "gearshape")
            }
            .tint(CanopyColor.primary)
        }
    }

    private func isAlias(_ alias: AliasFolder) -> Bool {
        if case let .alias(a) = subject { return a == alias }
        return false
    }

    // MARK: - Folder dialog hosts (feedback 0026, item 5)

    private func dialogBinding(for match: @escaping (FolderDialog) -> Bool) -> Binding<Bool> {
        Binding(
            get: { activeDialog.map(match) ?? false },
            set: { presented in if !presented, let d = activeDialog, match(d) { activeDialog = nil } }
        )
    }

    private var renameFolderAlertAnchor: some View {
        Color.clear
            .alert("Rename folder", isPresented: dialogBinding { $0.isRenameFolder }) {
                TextField("Name", text: $folderNameField)
                Button("Rename") {
                    // Capture through the SAME pure `FolderDialogAction.capture` seam the top-level screen
                    // uses (feedback 0026, item 4): read the payload synchronously before the dialog binding
                    // clears `activeDialog`. The root then does the store rename + re-points navigation.
                    performCaptured(FolderDialogAction.capture(from: activeDialog, name: folderNameField))
                }
                Button("Cancel", role: .cancel) { activeDialog = nil }
            }
    }

    private var deleteFolderAlertAnchor: some View {
        Color.clear
            .alert("Delete folder?", isPresented: dialogBinding { $0.isDeleteFolder }) {
                Button("Delete", role: .destructive) {
                    performCaptured(FolderDialogAction.capture(from: activeDialog, name: folderNameField))
                }
                Button("Cancel", role: .cancel) { activeDialog = nil }
            } message: {
                Text("This deletes the folder and everything inside it - its thoughts and their recordings. This can't be undone.")
            }
    }

    /// Dispatch a captured folder action (feedback 0026, item 4/5): the payload was read synchronously at tap
    /// time, so it is independent of `activeDialog` (which the dismissal clears). Rename and delete route to
    /// the root's callbacks, which do the store op and re-point / pop navigation.
    private func performCaptured(_ action: FolderDialogAction?) {
        guard let action else { return }
        activeDialog = nil
        switch action {
        case let .rename(path, newName):
            onRenameFolder?(path, newName)
        case let .delete(path):
            onDeleteFolder?(path)
        }
    }
}

/// The empty-state row shown INSIDE a user folder's / alias's list when it has thoughts nowhere for this
/// subject but the store is not empty overall (spec 0026): a gentle inline message rather than a bare list.
private struct EmptyFolderRow: View {
    let subject: FolderSubject

    private var message: String {
        switch subject {
        case .userFolder:
            return "This folder is empty. Move a thought here, or record one."
        case .alias:
            return "No thoughts yet."
        }
    }

    var body: some View {
        Text(message)
            .font(.system(size: CanopyFont.sizeSm))
            .foregroundStyle(CanopyColor.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CanopySpacing.x4)
            .unifiedRow()
    }
}
