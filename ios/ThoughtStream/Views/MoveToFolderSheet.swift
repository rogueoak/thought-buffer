import SwiftUI

/// The "Move to folder" picker sheet (spec 0010): presents "New folder...", "Top level", and every
/// existing folder in the tree indented by depth. Picking a destination re-saves the thought there (the
/// store relocates its `.md` and sibling `.m4a`), so a recorded thought keeps its recording.
///
/// The folder tree is walked once on appear via the injected `childFolders` closure (`store.folders`
/// through the feed, off the main actor) so an empty folder - which never appears in any thought's
/// `folderPath` - is still offered. Ordering is `FolderMoveTargets`' pre-order, A-Z among siblings.
struct MoveToFolderSheet: View {
    /// The thought being moved, used only to show its title and to know its current folder (so the
    /// current location is marked, not offered as a move onto itself).
    let thought: Thought
    /// Walk the folder tree: `childFolders([])` gives the top-level folders. Injected so the sheet
    /// does not reach into the store directly and stays testable via the feed.
    let childFolders: ([String]) async -> [String]
    /// Create a folder under `path`; returns the sanitized name used or nil when rejected. Used by the
    /// inline "New folder..." action so a destination can be made without leaving the sheet.
    let createFolder: (_ name: String, _ path: [String]) async -> String?
    /// Commit the move to `folderPath` (empty = top level). The sheet dismisses after calling this.
    let onMove: (_ folderPath: [String]) async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var targets: [FolderMoveTarget] = []
    @State private var loaded = false
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var newFolderError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        newFolderName = ""
                        showNewFolderAlert = true
                    } label: {
                        Label("New folder...", systemImage: "folder.badge.plus")
                            .foregroundStyle(CanopyColor.primary)
                    }
                }

                Section {
                    row(title: "Top level", systemImage: "tray", depth: 0, isCurrent: thought.folderPath.isEmpty) {
                        Task { await onMove([]); dismiss() }
                    }
                    ForEach(targets) { target in
                        row(
                            title: target.name,
                            systemImage: "folder",
                            depth: target.depth + 1,
                            isCurrent: target.path == thought.folderPath
                        ) {
                            Task { await onMove(target.path); dismiss() }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Move to folder")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if loaded, targets.isEmpty {
                    Text("No folders yet. Use \"New folder...\" to make one.")
                        .font(.system(size: CanopyFont.sizeSm))
                        .foregroundStyle(CanopyColor.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, CanopySpacing.x8)
                        .allowsHitTesting(false)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .tint(CanopyColor.primary)
                }
            }
            .alert("New folder", isPresented: $showNewFolderAlert) {
                TextField("Name", text: $newFolderName)
                Button("Create") { Task { await createNewFolder() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let newFolderError {
                    Text(newFolderError)
                } else {
                    Text("Create a folder at the top level.")
                }
            }
        }
        .tint(CanopyColor.primary)
        .task { await loadTree() }
    }

    /// Pre-walk the whole folder tree into a flat cache, then feed it to the pure `FolderMoveTargets`
    /// builder. The builder is synchronous (pure), but the store walk is async (iCloud coordination),
    /// so the walk happens here and the builder reads the cache.
    private func loadTree() async {
        var cache: [[String]: [String]] = [:]
        var queue: [[String]] = [[]]
        while let path = queue.first {
            queue.removeFirst()
            let names = await childFolders(path)
            cache[path] = names
            for name in names { queue.append(path + [name]) }
        }
        targets = FolderMoveTargets.all(children: { cache[$0] ?? [] })
        loaded = true
    }

    private func createNewFolder() async {
        // Create at the top level from this sheet (nested creation happens by navigating in the main
        // list). Report a rejected/empty name in the alert message on re-open.
        let created = await createFolder(newFolderName, [])
        if created == nil {
            newFolderError = "That name can't be used. Try another."
            showNewFolderAlert = true
            return
        }
        newFolderError = nil
        await loadTree()
    }

    @ViewBuilder
    private func row(
        title: String,
        systemImage: String,
        depth: Int,
        isCurrent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: CanopySpacing.x2) {
                Image(systemName: systemImage)
                    .foregroundStyle(CanopyColor.primary)
                Text(title)
                    .foregroundStyle(CanopyColor.text)
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(CanopyColor.textSubtle)
                }
            }
            .padding(.leading, CGFloat(depth) * CanopySpacing.x4)
        }
        .disabled(isCurrent)
    }
}
