import SwiftUI

/// The folder-aware Thoughts screen at ONE folder path (spec 0010). Root is `path: []`; a folder
/// pushed on the stack renders another instance at its own path, so this view recurses.
///
/// It shows the child folders at `currentPath` and the notes whose `folderPath == currentPath`,
/// INTERLEAVED into one list sorted by the chosen `NoteSortOrder` (via `FolderListModel`). Folder rows
/// navigate (tap = push); note rows navigate to detail. Folder rows carry Rename / Delete; note rows
/// carry Move-to-folder and swipe-to-delete. The toolbar adds new-folder + sort, and the record button
/// is pinned in the bottom safe area, exactly as the flat stream had it.
struct FolderContentsView: View {
    @ObservedObject var feed: StreamFeed
    /// This screen's folder path (root = []). Notes shown are those whose `folderPath` equals this;
    /// folders shown are its children.
    let currentPath: [String]
    /// The shared sort order, bound so the toolbar menu here re-sorts the whole app live.
    @Binding var sortOrder: NoteSortOrder

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
    let onNewThought: () -> Void
    let onOpenSettings: () -> Void
    /// Soft-delete a note by id through the shared undoable path (spec 0020), so the list swipe and the
    /// list-row context-menu Delete both route through the composition root's `NoteDeletionController`
    /// (which registers undo + shows the affordance) rather than deleting the store directly.
    let onDeleteNote: (UUID) -> Void

    /// The child folder names at this path, loaded off-main (the store walk can coordinate on iCloud)
    /// and refreshed after a folder edit. Kept local to this screen so each path shows its own folders.
    @State private var childFolderNames: [String] = []
    @State private var folderLoaded = false

    // New-folder alert.
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""

    // Rename alert (targets a specific child folder path).
    @State private var renameTarget: [String]?
    @State private var renameName = ""

    // Delete confirmation (targets a specific child folder path).
    @State private var deleteTarget: [String]?

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

    var body: some View {
        Group {
            if items.isEmpty && feed.didLoad && folderLoaded {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CanopyColor.bg.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: CanopySpacing.x3) {
                // The now-playing bar sits ABOVE the Record button on every folder screen (spec 0015),
                // shown only while the shared controller has a loaded note. Tapping its title routes to
                // that note via the same `onOpenNote` the rows use.
                if let controller = playbackController {
                    NowPlayingBar(controller: controller, onOpenNote: onOpenNote)
                }
                RecordButton { onNewThought() }
            }
            .padding(.bottom, CanopySpacing.x6)
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
        // The shared, lifecycle-tied "Copied to clipboard" confirmation (spec 0017), pinned at the top
        // like the sibling banners; a rapid re-copy re-arms it and navigation cancels its timer.
        .copiedConfirmation(trigger: copiedTrigger, isShown: $showCopiedConfirmation, alignment: .top)
        .animation(.easeInOut(duration: 0.2), value: feed.deleteFailed)
        .animation(.easeInOut(duration: 0.2), value: folderError)
        .toolbar { toolbarContent }
        .alert("New folder", isPresented: $showNewFolderAlert) {
            TextField("Name", text: $newFolderName)
            Button("Create") { Task { await createFolder() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create a folder here.")
        }
        .alert("Rename folder", isPresented: renameAlertBinding) {
            TextField("Name", text: $renameName)
            Button("Rename") { Task { await renameFolder() } }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("Delete folder?", isPresented: deleteAlertBinding) {
            Button("Delete", role: .destructive) { Task { await deleteFolder() } }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("This deletes the folder and everything inside it - notes, recordings, and subfolders. This can't be undone.")
        }
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

    // MARK: - List

    private var list: some View {
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
                renameName = name
                renameTarget = folderPath
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleteTarget = folderPath
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
                deleteTarget = folderPath
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                renameName = name
                renameTarget = folderPath
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
                newFolderName = ""
                showNewFolderAlert = true
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
        ToolbarItem(placement: .topBarTrailing) {
            Button { onNewNote(currentPath) } label: {
                Image(systemName: "square.and.pencil")
            }
            .tint(CanopyColor.primary)
            .accessibilityLabel("New note")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { onNewThought() } label: {
                Image(systemName: "mic.fill")
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

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: CanopySpacing.x3) {
            Image(systemName: currentPath.isEmpty ? "waveform" : "folder")
                .font(.system(size: CanopyFont.sizeX4xl, weight: .semibold))
                .foregroundStyle(CanopyColor.primary)
            Text(currentPath.isEmpty ? "No notes yet" : "This folder is empty")
                .font(.system(size: CanopyFont.sizeXl, weight: .semibold))
                .foregroundStyle(CanopyColor.text)
            Text(currentPath.isEmpty
                ? "Tap Record and start talking. Your words land here as a note."
                : "Move a note here, or create a folder inside it.")
                .font(.system(size: CanopyFont.sizeSm))
                .foregroundStyle(CanopyColor.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CanopySpacing.x8)
        }
    }

    // MARK: - Alert bindings

    private var renameAlertBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    // MARK: - Actions

    private func reloadFolders() async {
        childFolderNames = await feed.childFolders(at: currentPath)
        folderLoaded = true
    }

    private func createFolder() async {
        let created = await feed.createFolder(named: newFolderName, at: currentPath)
        await reloadFolders()
        if created == nil {
            folderError = "That name can't be used. Try another."
        }
    }

    private func renameFolder() async {
        guard let target = renameTarget else { return }
        renameTarget = nil
        let renamed = await feed.renameFolder(at: target, to: renameName)
        await reloadFolders()
        if renamed == nil {
            folderError = "Couldn't rename - the name is invalid or already used."
        }
    }

    private func deleteFolder() async {
        guard let target = deleteTarget else { return }
        deleteTarget = nil
        await feed.deleteFolder(at: target)
        await reloadFolders()
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
