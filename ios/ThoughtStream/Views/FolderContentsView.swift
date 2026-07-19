import SwiftUI

/// The folder-aware Thoughts screen at ONE folder path (spec 0010). Root is `path: []`; a folder
/// pushed on the stack renders another instance at its own path, so this view recurses.
///
/// It shows the child folders at `currentPath` and the notes whose `folderPath == currentPath`,
/// INTERLEAVED into one list sorted by the chosen `NoteSortOrder` (via `FolderListModel`). Folder rows
/// navigate (tap = push); note rows navigate to detail. Folder rows carry Rename / Delete; note rows
/// carry Move-to-folder and swipe-to-delete.
///
/// Spec 0021 gives it the persistent bottom bar (search field + icon-only new-note + record) and
/// GLOBAL full-text search: typing filters `feed.notes` across the WHOLE tree to a flat results list
/// (via `NoteSearch`); tapping a result opens it; clearing restores the normal folder list. An empty
/// store shows a centered record + new-note CTA instead of an empty list; a non-empty store filtered to
/// zero matches shows a "no matches" state with the field still visible. The state selection is the
/// pure `FolderScreenState`.
struct FolderContentsView: View {
    @ObservedObject var feed: StreamFeed
    /// This screen's folder path (root = []). Notes shown are those whose `folderPath` equals this;
    /// folders shown are its children.
    let currentPath: [String]
    /// The shared sort order, bound so the toolbar menu here re-sorts the whole app live.
    @Binding var sortOrder: NoteSortOrder
    /// The live search query for the persistent bottom bar (spec 0021). Non-whitespace text switches the
    /// screen to the flat global results list; clearing it restores the normal folder view. Bound from
    /// the root (`StreamListView`) so a search initiated on the note-detail page can pop back and land in
    /// the ROOT folder screen's field, driving the same global results.
    @Binding var searchQuery: String

    /// The ONE shared playback controller (spec 0008), threaded down so a leading swipe can play a note
    /// or a folder's queue through the same path the detail view, CarPlay, and the now-playing bar
    /// drive (spec 0015). Optional so a preview / screenshot build without shared playback still
    /// renders; the swipe Play actions are simply omitted when nil.
    let playbackController: NotePlaybackController?

    let onOpenFolder: ([String]) -> Void
    let onOpenNote: (Note) -> Void
    /// Create a blank keyboard note filed in this screen's folder (spec 0013). Carries `currentPath`
    /// so the new note lands in the folder the user is currently browsing.
    let onNewNote: ([String]) -> Void
    /// Start a new dictation session (the mic / Record action), filed into the folder path passed in so
    /// a thought recorded while browsing a folder lands in THAT folder, not at the root (feedback: the
    /// record action must be contextual, like the new-note action). Carries `currentPath`.
    let onNewThought: ([String]) -> Void
    let onOpenSettings: () -> Void
    /// Soft-delete a note by id through the shared undoable path (spec 0020), so the list swipe and the
    /// list-row context-menu Delete both route through the composition root's `NoteDeletionController`
    /// (which registers undo + shows the affordance) rather than deleting the store directly.
    let onDeleteNote: (UUID) -> Void
    /// The shared undoable-delete coordinator (spec 0020), owned by the root and observed here so the
    /// "Note deleted - Undo" affordance renders in THIS screen's bottom stack, ABOVE the now-playing bar
    /// and persistent bottom bar (spec 0021 reconciliation) - so the three compose via one VStack rather
    /// than a hardcoded overlay clearance. Optional so a preview / bare call site without a coordinator
    /// simply omits the chip; the root still owns the UndoManager wiring and the window timer.
    @ObservedObject var deletion: NoteDeletionController

    /// The child folder names at this path, loaded off-main (the store walk can coordinate on iCloud)
    /// and refreshed after a folder edit. Kept local to this screen so each path shows its own folders.
    @State private var childFolderNames: [String] = []
    @State private var folderLoaded = false

    /// The single active folder dialog (spec 0021 rename-bug fix). The New folder / Rename folder /
    /// Delete folder dialogs were three STACKED `.alert(...)` modifiers on one view, each driven by its
    /// own `@State`, with rename/delete presented straight from a `.contextMenu` action - a classic
    /// SwiftUI flakiness source where a stacked alert may fail to present or a rename never applies. They
    /// are now ONE `.alert(item:)` host driven by this single enum, so exactly one alert node exists and
    /// its presentation is item-driven (reliable) rather than a bool that races the context-menu
    /// dismissal. The rename/new-folder text lives in the separate `folderNameField` so the TextField
    /// binding is stable across the item change.
    @State private var activeDialog: FolderDialog?
    /// The text field backing the New folder and Rename folder alerts. Seeded when the dialog opens and
    /// read when its action runs, kept out of the enum so editing it does not churn the item identity.
    @State private var folderNameField = ""

    // Move-to-folder sheet (targets a specific note).
    @State private var moveNote: Note?

    // A transient message for a rejected/conflicting folder name.
    @State private var folderError: String?

    // Drives the shared "Copied to clipboard" confirmation after a note-row Copy text (spec 0017):
    // `copiedTrigger` is bumped on each copy so the lifecycle-tied confirmation re-arms its auto-hide,
    // and `showCopiedConfirmation` holds its visibility.
    @State private var copiedTrigger = 0
    @State private var showCopiedConfirmation = false

    /// The interleaved, sorted rows for this screen: child folders + notes at this path.
    private var items: [FolderListItem] {
        FolderListModel.items(
            allNotes: feed.notes,
            childFolderNames: childFolderNames,
            currentPath: currentPath,
            sortOrder: sortOrder
        )
    }

    /// Resolve the screen state AND the search results in ONE pass (architect review): the search scan is
    /// `notes x paragraphs`, so it must run at most ONCE per render, not once in the body and again inside
    /// a separate `screenState` computed property (which re-scanned per keystroke). When no search is
    /// active the scan is skipped entirely. Gated on the initial load so a not-yet-loaded feed does not
    /// flash the empty CTA. `storeHasNotes` is the WHOLE store (search is global), so the empty-state CTA
    /// shows only when there is genuinely nothing anywhere.
    private func resolveContent() -> (state: FolderScreenState, results: [Note]) {
        guard feed.didLoad, folderLoaded else { return (.normal, []) }
        let active = NoteSearch.isActive(searchQuery)
        // Only scan when a search is active; the normal/empty states never look at results.
        let results = active ? NoteSearch.results(in: feed.notes, query: searchQuery) : []
        let state = FolderScreenState.select(
            storeHasNotes: !feed.notes.isEmpty,
            searchActive: active,
            hasSearchMatches: !results.isEmpty
        )
        return (state, results)
    }

    var body: some View {
        let content = resolveContent()
        return bodyContent(state: content.state, results: content.results)
    }

    /// The screen body for a resolved `state`/`results` (computed once per render in `body`), so the
    /// search scan is not repeated. `state` drives which view shows; `results` feeds the search list.
    @ViewBuilder
    private func bodyContent(state screenState: FolderScreenState, results searchResults: [Note]) -> some View {
        Group {
            switch screenState {
            case .emptyStore:
                FolderEmptyStateCTA(
                    isRoot: currentPath.isEmpty,
                    onRecord: { onNewThought(currentPath) },
                    onNewNote: { onNewNote(currentPath) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .searchResults:
                searchResultsList(searchResults)
            case .noMatches:
                noMatchesState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .normal:
                normalContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CanopyColor.bg.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { bottomStack(state: screenState) }
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
        // The shared, lifecycle-tied "Copied to clipboard" confirmation (spec 0017), pinned at the top
        // like the sibling banners; a rapid re-copy re-arms it and navigation cancels its timer.
        .copiedConfirmation(trigger: copiedTrigger, isShown: $showCopiedConfirmation, alignment: .top)
        .animation(.easeInOut(duration: 0.2), value: feed.deleteFailed)
        .animation(.easeInOut(duration: 0.2), value: folderError)
        .toolbar { toolbarContent }
        // The folder dialogs (spec 0021 rename-bug fix). All three were STACKED `.alert`s on this one
        // view node, which is a classic SwiftUI flakiness source (a sibling alert can swallow another's
        // presentation, and a rename triggered from a `.contextMenu` may never present or apply). Each
        // alert now hangs off its OWN hidden background anchor, driven by the single `activeDialog` enum
        // via per-case bindings, so no two alerts share a node and none can lose the race. Alerts keep
        // the TextField form (the item-based `Alert` value has no text field), just un-stacked.
        .background(newFolderAlertAnchor)
        .background(renameFolderAlertAnchor)
        .background(deleteFolderAlertAnchor)
        .sheet(item: $moveNote) { note in
            MoveToFolderSheet(
                note: note,
                childFolders: { await feed.childFolders(at: $0) },
                createFolder: { name, path in await feed.createFolder(named: name, at: path) },
                onMove: { folderPath in
                    await feed.move(note, to: folderPath)
                    await reloadFolders()
                }
            )
        }
        .task(id: feed.reloadGeneration) {
            // Reload this path's child folders whenever the feed republishes (a folder edit, a save, or
            // an external iCloud change). `reloadGeneration` bumps on EVERY republish, so it catches
            // changes the note count would miss: a rename, a move between two existing folders, or a
            // synced-in empty folder.
            await reloadFolders()
        }
    }

    // MARK: - Bottom stack (spec 0021)

    /// The composed bottom safe-area stack (spec 0021 reconciliation of the three bottom affordances):
    /// from top to bottom, the transient "Note deleted - Undo" chip (spec 0020), the now-playing bar
    /// (spec 0015), then the persistent bottom bar (spec 0021), all in ONE inset so they stack cleanly
    /// via the SHARED VStack spacing and reserve real layout space - no hardcoded overlay clearance, and
    /// no overlap. Each element appears only when relevant (undo chip while a delete is pending,
    /// now-playing bar while something plays), so the stack is just the bottom bar in the common case.
    /// The bar hides its search field in a truly empty store but still shows Record, so recording is
    /// always reachable.
    private func bottomStack(state screenState: FolderScreenState) -> some View {
        VStack(spacing: CanopySpacing.x3) {
            if deletion.pending != nil {
                UndoDeleteAffordance(onUndo: { Task { await deletion.undo() } })
                    .transition(.opacity)
            }
            // In a truly empty store the centered CTA already carries labeled Record + New-note buttons
            // (spec 0021), so the bottom bar (which would only duplicate them, with no field to search)
            // is omitted; the undo chip above can still show while a just-deleted note is pending.
            if screenState != .emptyStore {
                if let controller = playbackController {
                    NowPlayingBar(controller: controller, onOpenNote: onOpenNote)
                }
                BottomBar(query: $searchQuery, showsSearchField: screenState.showsSearchField) {
                    BottomBarIconButton(
                        systemImage: "square.and.pencil",
                        accessibilityLabel: "New note"
                    ) { onNewNote(currentPath) }
                    BottomBarRecordButton(accessibilityLabel: "Record") { onNewThought(currentPath) }
                }
            }
        }
        .padding(.bottom, CanopySpacing.x2)
        .animation(.easeInOut(duration: 0.2), value: deletion.pending != nil)
        // The undo window's ~5s timer is lifecycle-tied to THIS view (spec 0020), the same shape as the
        // copied-confirmation chip: keyed on the monotonic delete trigger so a rapid second delete
        // re-arms it and navigation cancels it, never a detached timer. On expiry with a still-pending
        // delete it commits (purges). The root still owns the UndoManager + scene-phase commit.
        .task(id: deletion.deleteTrigger) {
            guard deletion.deleteTrigger > 0, deletion.pending != nil else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await deletion.commitWindow()
        }
    }

    // MARK: - Lists

    private var normalContent: some View {
        List {
            ForEach(items) { item in
                switch item {
                case let .folder(name, folderPath):
                    folderRow(name: name, folderPath: folderPath)
                case let .note(note):
                    noteRow(note: note)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .padding(.top, CanopySpacing.x2)
    }

    /// The flat GLOBAL search results (spec 0021): every matching note anywhere in the tree, as note
    /// rows. Tapping opens the note; the rows keep their swipe/context actions so a match can be played,
    /// moved, shared, or deleted in place. `results` is computed ONCE per render in `body` (not rescanned
    /// here) so a keystroke does not re-run the notes x paragraphs scan.
    private func searchResultsList(_ results: [Note]) -> some View {
        List {
            ForEach(results) { note in
                noteRow(note: note)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .padding(.top, CanopySpacing.x2)
    }

    private func folderRow(name: String, folderPath: [String]) -> some View {
        Button {
            onOpenFolder(folderPath)
        } label: {
            FolderRow(
                name: name,
                countLabel: FolderListModel.noteCountLabel(
                    FolderListModel.descendantNoteCount(of: folderPath, in: feed.notes)
                )
            )
        }
        .buttonStyle(.plain)
        .rowInsets()
        .contextMenu {
            Button {
                beginRename(name: name, path: folderPath)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                activeDialog = .deleteFolder(path: folderPath)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            // A full leading swipe plays the folder's recordings as a queue (spec 0015): every recorded
            // note anywhere in this folder's subtree, in the current sort order, auto-advancing. A
            // folder with no recordings plays nothing (the controller no-ops on an empty queue).
            if let controller = playbackController {
                Button {
                    controller.playQueue(folderQueue(for: folderPath))
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .tint(CanopyColor.success)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                activeDialog = .deleteFolder(path: folderPath)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                beginRename(name: name, path: folderPath)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(CanopyColor.primary)
        }
    }

    /// The play queue for a folder swipe (spec 0015): every note anywhere in `folderPath`'s subtree
    /// (its `folderPath` has `folderPath` as a prefix) that carries a recording, ordered by the current
    /// `NoteSortOrder` via the shared comparator - so a folder plays in the same order its notes appear
    /// in the list. The controller filters to recordings too, but filtering here keeps the ordering
    /// honest (it sorts only the notes that will actually play).
    private func folderQueue(for folderPath: [String]) -> [Note] {
        let inSubtree = feed.notes.filter { note in
            note.hasAudio && FolderListModel.isDescendant(note.folderPath, of: folderPath)
        }
        return sortOrder.sort(inSubtree)
    }

    private func noteRow(note: Note) -> some View {
        Button {
            onOpenNote(note)
        } label: {
            NoteCard(note: note)
        }
        .buttonStyle(.plain)
        .rowInsets()
        .contextMenu {
            // Long-press a note row for Share + Copy from the ONE shared `NoteActionsMenu` (spec 0017),
            // with this screen's Move-to-folder appended after them. `onCopied` bumps the trigger that
            // flashes the shared confirmation. Folder rows get no share/copy - only notes.
            NoteActionsMenu(note: note, onCopied: { copiedTrigger += 1 }) {
                Button {
                    moveNote = note
                } label: {
                    Label("Move to folder", systemImage: "folder")
                }
                // Delete via the shared undoable path (spec 0020): the same route the swipe uses, so
                // every entry point registers undo and shows the affordance. Destructive role tints it.
                Button(role: .destructive) {
                    onDeleteNote(note.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            // A full leading swipe plays a recorded note immediately through the shared controller
            // (spec 0015); a text-only note gets no Play action, only Move.
            if note.hasAudio, let controller = playbackController {
                Button {
                    controller.play(note: note)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .tint(CanopyColor.success)
            }
            Button {
                moveNote = note
            } label: {
                Label("Move", systemImage: "folder")
            }
            .tint(CanopyColor.primary)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            // The swipe deletes through the SAME undoable path (spec 0020) as the menus, so it registers
            // undo and shows the affordance instead of hard-deleting the store.
            Button(role: .destructive) {
                onDeleteNote(note.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
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
                    ForEach(NoteSortOrder.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .tint(CanopyColor.primary)
        }
        // The new-note + record actions moved to the persistent bottom bar (spec 0021); the top-right
        // keeps only Settings so the gear stays where it always was.
        ToolbarItem(placement: .topBarTrailing) {
            Button { onOpenSettings() } label: {
                Image(systemName: "gearshape")
            }
            .tint(CanopyColor.primary)
        }
    }

    // MARK: - No-matches state

    /// Shown when a search is active but matched nothing in a non-empty store (spec 0021). The search
    /// field stays visible (it lives in the bottom bar), so the user can edit or clear the query.
    private var noMatchesState: some View {
        VStack(spacing: CanopySpacing.x3) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: CanopyFont.sizeX4xl, weight: .semibold))
                .foregroundStyle(CanopyColor.primary)
            Text("No matches")
                .font(.system(size: CanopyFont.sizeXl, weight: .semibold))
                .foregroundStyle(CanopyColor.text)
            Text("No note's title or text contains \"\(trimmedQuery)\".")
                .font(.system(size: CanopyFont.sizeSm))
                .foregroundStyle(CanopyColor.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CanopySpacing.x8)
        }
    }

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Folder dialog hosts (spec 0021 rename-bug fix)

    /// Open the rename dialog for a folder, seeding the shared name field with its current name (so the
    /// user edits from what they see). Setting the enum + field together, from one place, keeps the
    /// context-menu and swipe entry points identical.
    private func beginRename(name: String, path: [String]) {
        folderNameField = name
        activeDialog = .renameFolder(path: path, currentName: name)
    }

    /// A per-case presentation binding off the single `activeDialog` enum: true while THAT case is
    /// active, and clearing it dismisses. Each alert anchor uses its own so no two share a node.
    private func dialogBinding(for match: @escaping (FolderDialog) -> Bool) -> Binding<Bool> {
        Binding(
            get: { activeDialog.map(match) ?? false },
            set: { presented in if !presented, let d = activeDialog, match(d) { activeDialog = nil } }
        )
    }

    /// Hidden anchor hosting ONLY the New folder alert, so it is not stacked with the others.
    private var newFolderAlertAnchor: some View {
        Color.clear
            .alert("New folder", isPresented: dialogBinding { $0.isNewFolder }) {
                folderNameTextField(placeholder: "Name")
                Button("Create") { Task { await createFolder() } }
                Button("Cancel", role: .cancel) { activeDialog = nil }
            } message: {
                Text("Create a folder here.")
            }
    }

    /// Hidden anchor hosting ONLY the Rename folder alert.
    private var renameFolderAlertAnchor: some View {
        Color.clear
            .alert("Rename folder", isPresented: dialogBinding { $0.isRenameFolder }) {
                folderNameTextField(placeholder: "Name")
                Button("Rename") { Task { await renameFolder() } }
                Button("Cancel", role: .cancel) { activeDialog = nil }
            }
    }

    /// Hidden anchor hosting ONLY the Delete folder confirmation.
    private var deleteFolderAlertAnchor: some View {
        Color.clear
            .alert("Delete folder?", isPresented: dialogBinding { $0.isDeleteFolder }) {
                Button("Delete", role: .destructive) { Task { await deleteFolder() } }
                Button("Cancel", role: .cancel) { activeDialog = nil }
            } message: {
                Text("This deletes the folder and everything inside it - notes, recordings, and subfolders. This can't be undone.")
            }
    }

    /// The shared TextField for the New folder / Rename folder alerts, bound to `folderNameField`.
    private func folderNameTextField(placeholder: String) -> some View {
        TextField(placeholder, text: $folderNameField)
    }

    // MARK: - Actions

    private func reloadFolders() async {
        childFolderNames = await feed.childFolders(at: currentPath)
        folderLoaded = true
    }

    private func createFolder() async {
        let name = folderNameField
        activeDialog = nil
        let created = await feed.createFolder(named: name, at: currentPath)
        await reloadFolders()
        if created == nil {
            folderError = "That name can't be used. Try another."
        }
    }

    /// Apply a pending rename. Reads the target path off the active dialog and the new name off the
    /// shared field, clears the dialog, then renames through the feed and reloads. A nil result (invalid
    /// or already-used name) surfaces the advisory banner. This is the path the old stacked-alert bug
    /// could skip entirely; the single un-stacked alert host now presents and applies reliably.
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

/// The single active folder dialog on a folder screen (spec 0021 rename-bug fix). One enum drives all
/// three dialogs from ONE state so they are no longer three stacked `.alert`s racing each other; each is
/// hosted on its own hidden anchor via a per-case binding. `Identifiable` for stable presentation.
enum FolderDialog: Identifiable, Equatable {
    case newFolder
    case renameFolder(path: [String], currentName: String)
    case deleteFolder(path: [String])

    var id: String {
        switch self {
        case .newFolder: return "new"
        case let .renameFolder(path, _): return "rename:" + path.joined(separator: "/")
        case let .deleteFolder(path): return "delete:" + path.joined(separator: "/")
        }
    }

    var isNewFolder: Bool { if case .newFolder = self { return true }; return false }
    var isRenameFolder: Bool { if case .renameFolder = self { return true }; return false }
    var isDeleteFolder: Bool { if case .deleteFolder = self { return true }; return false }
}

/// The empty-state call to action (spec 0021): when a list or folder has no notes anywhere, show the
/// RECORD button in the middle of the screen WITH its text label, and a NEW-NOTE button directly below
/// it. This is the ONE place record/new-note keep their labels (the persistent bottom bar drops them).
struct FolderEmptyStateCTA: View {
    /// Whether this is the root list (vs a folder), only for the supporting copy.
    let isRoot: Bool
    let onRecord: () -> Void
    let onNewNote: () -> Void

    var body: some View {
        VStack(spacing: CanopySpacing.x4) {
            Image(systemName: "waveform")
                .font(.system(size: CanopyFont.sizeX4xl, weight: .semibold))
                .foregroundStyle(CanopyColor.primary)
            Text(isRoot ? "No notes yet" : "This folder is empty")
                .font(.system(size: CanopyFont.sizeXl, weight: .semibold))
                .foregroundStyle(CanopyColor.text)
            Text("Tap Record and start talking, or make a note with the keyboard.")
                .font(.system(size: CanopyFont.sizeSm))
                .foregroundStyle(CanopyColor.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CanopySpacing.x8)

            // Record in the middle WITH its label, new-note directly below it (spec 0021).
            RecordButton(action: onRecord)
                .padding(.top, CanopySpacing.x2)
            Button(action: onNewNote) {
                HStack(spacing: CanopySpacing.x2) {
                    Image(systemName: "square.and.pencil")
                    Text("New note")
                        .font(.system(size: CanopyFont.sizeBase, weight: .semibold))
                }
                .foregroundStyle(CanopyColor.primary)
                .padding(.horizontal, CanopySpacing.x6)
                .padding(.vertical, CanopySpacing.x3)
                .overlay(
                    Capsule().stroke(CanopyColor.primary, lineWidth: 1)
                )
            }
            .accessibilityLabel("New note")
        }
    }
}

/// A brief, non-blocking banner for a rejected/conflicting folder name, styled with Canopy warning
/// tokens so it reads as an advisory rather than a destructive error.
private struct FolderErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: CanopySpacing.x2) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(message)
                .font(.system(size: CanopyFont.sizeSm, weight: .semibold))
        }
        .foregroundStyle(CanopyColor.warningForeground)
        .padding(.horizontal, CanopySpacing.x4)
        .padding(.vertical, CanopySpacing.x2)
        .background(CanopyColor.warning)
        .clipShape(Capsule())
        .shadow(color: CanopyColor.overlay.opacity(0.2), radius: 8, y: 4)
        .padding(.top, CanopySpacing.x2)
    }
}

/// The shared row insets that keep every card's surface/border inset from the list edges, matching the
/// original flat stream (feedback 0005).
private extension View {
    func rowInsets() -> some View {
        self
            .listRowInsets(EdgeInsets(
                top: CanopySpacing.x1_5,
                leading: CanopySpacing.x4,
                bottom: CanopySpacing.x1_5,
                trailing: CanopySpacing.x4
            ))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
