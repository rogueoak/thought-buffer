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

    /// What this screen shows: a user folder (by name) or a virtual alias. Drives the title, the thought
    /// projection, and whether new-thought placement is contextual (a user folder) or uncategorized (alias).
    enum Subject: Hashable {
        case userFolder(String)
        case alias(AliasFolder)

        var title: String {
            switch self {
            case let .userFolder(name): return name
            case let .alias(alias): return alias.title
            }
        }
    }

    let subject: Subject
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

    /// Whether this screen renders its own bottom stack (compact stack: true; split columns: false, the
    /// stack is lifted). Same contract as the retired interleaving screen.
    var showsBottomBar: Bool = true
    /// A pre-resolved search projection injected by the split container so the columns share ONE scan.
    var resolvedContent: StreamSearchProjection.Result?

    @State private var moveThought: Thought?
    @State private var copiedTrigger = 0
    @State private var showCopiedConfirmation = false

    /// The placement `folderPath` for a new thought created on this screen (spec 0026): a user folder files
    /// contextually into `[name]`; an alias files uncategorized (`[]`).
    private var newThoughtFolderPath: [String] {
        switch subject {
        case let .userFolder(name): return NewThoughtPlacement.folderPath(browsingFolder: [name])
        case .alias: return NewThoughtPlacement.folderPath(browsingFolder: [])
        }
    }

    /// The thoughts shown, projected purely from the loaded list per the subject and sort order.
    private var thoughts: [Thought] {
        switch subject {
        case let .userFolder(name):
            return TopLevelFolders.folderThoughts(feed.thoughts, folder: name, sorted: sortOrder)
        case let .alias(alias):
            switch alias {
            case .allThoughts:
                return TopLevelFolders.allThoughts(feed.thoughts, sorted: sortOrder)
            case .recents:
                return TopLevelFolders.recents(feed.thoughts)
            }
        }
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
            .sheet(item: $moveThought) { thought in
                MoveToFolderSheet(
                    thought: thought,
                    childFolders: { await feed.childFolders(at: $0) },
                    createFolder: { name, path in await feed.createFolder(named: name, at: path) },
                    onMove: { folderPath in await feed.move(thought, to: folderPath) }
                )
            }
    }

    @ViewBuilder
    private func switchingContent(state screenState: FolderScreenState, results searchResults: [Thought]) -> some View {
        switch screenState {
        case .emptyStore:
            // A truly empty store (no thoughts anywhere): the centered CTA. Reachable from the aliases and
            // from a fresh user folder that is empty and the store has nothing.
            FolderEmptyStateCTA(
                isRoot: false,
                onRecord: { onNewThought(newThoughtFolderPath) },
                onNewKeyboardThought: { onNewKeyboardThought(newThoughtFolderPath) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .searchResults:
            thoughtList(searchResults, showTitle: false)
        case .noMatches:
            NoSearchMatchesState(query: searchQuery)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .normal:
            thoughtList(thoughts, showTitle: true)
        }
    }

    /// The flat thought list. When `showTitle` is true the screen title is the FIRST row (scrolls away, spec
    /// 0026); the search-results list drops the title (the query is the context there).
    private func thoughtList(_ rows: [Thought], showTitle: Bool) -> some View {
        List {
            if showTitle {
                StreamListTitleRow(title: subject.title)
            }
            if showTitle, rows.isEmpty {
                EmptyFolderRow(subject: subject)
            }
            ForEach(rows) { thought in
                thoughtRow(thought: thought)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func thoughtRow(thought: Thought) -> some View {
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
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if thought.hasAudio, let controller = playbackController {
                Button {
                    controller.play(thought: thought)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .tint(CanopyColor.success)
            }
            Button {
                moveThought = thought
            } label: {
                Label("Move", systemImage: "folder")
            }
            .tint(CanopyColor.primary)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDeleteThought(thought.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
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
}

/// The empty-state row shown INSIDE a user folder's / alias's list when it has thoughts nowhere for this
/// subject but the store is not empty overall (spec 0026): a gentle inline message rather than a bare list.
private struct EmptyFolderRow: View {
    let subject: FolderThoughtsView.Subject

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
            .tightRowInsets()
    }
}
