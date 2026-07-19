import SwiftUI

/// A multi-select picker to move existing thoughts INTO a folder (feedback 0026, item 6). It is the inverse
/// of `MoveToFolderSheet` (which moves ONE thought TO a chosen folder): here the destination folder is fixed
/// (the empty folder the user is viewing) and the user selects WHICH thoughts to pull in. It lists ALL
/// thoughts across the store - already-in-this-folder ones are excluded, since moving them here is a no-op -
/// with a checkmark toggle per row, and a "Move" action that re-files every selected thought into the folder.
///
/// Moving is the same re-save-with-a-new-`folderPath` the rest of the app uses (the store relocates each
/// thought's `.md` and sibling `.m4a`), so a recorded thought keeps its recording.
struct MoveThoughtsIntoFolderSheet: View {
    /// The destination folder name (a top-level user folder, spec 0026 is one level deep).
    let folderName: String
    /// Every thought in the store, newest first (the feed's loaded list).
    let allThoughts: [Thought]
    /// Move the selected thoughts into `[folderName]`. Called once with all selected ids; the host re-files
    /// each and reloads.
    let onMove: (_ ids: Set<UUID>) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []

    /// Thoughts that are NOT already in this folder (moving those here is a no-op), so only movable ones show.
    private var candidates: [Thought] {
        allThoughts.filter { $0.folderPath.first != folderName }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Move to \(folderName)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                            .tint(CanopyColor.primary)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Move") {
                            let ids = selected
                            Task { await onMove(ids); dismiss() }
                        }
                        .tint(CanopyColor.primary)
                        .disabled(selected.isEmpty)
                    }
                }
        }
        .tint(CanopyColor.primary)
    }

    @ViewBuilder
    private var content: some View {
        if candidates.isEmpty {
            VStack(spacing: CanopySpacing.x3) {
                Image(systemName: "folder")
                    .font(.system(size: CanopyFont.sizeX4xl, weight: .semibold))
                    .foregroundStyle(CanopyColor.primary)
                Text("No thoughts to move")
                    .font(.system(size: CanopyFont.sizeXl, weight: .semibold))
                    .foregroundStyle(CanopyColor.text)
                Text("Every thought is already in this folder, or there are none yet.")
                    .font(.system(size: CanopyFont.sizeSm))
                    .foregroundStyle(CanopyColor.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, CanopySpacing.x8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CanopyColor.bg.ignoresSafeArea())
        } else {
            List {
                ForEach(candidates) { thought in
                    row(for: thought)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func row(for thought: Thought) -> some View {
        let isSelected = selected.contains(thought.id)
        return Button {
            if isSelected {
                selected.remove(thought.id)
            } else {
                selected.insert(thought.id)
            }
        } label: {
            HStack(spacing: CanopySpacing.x3) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? CanopyColor.primary : CanopyColor.textSubtle)
                VStack(alignment: .leading, spacing: CanopySpacing.x1) {
                    Text(thought.title)
                        .font(.system(size: CanopyFont.sizeBase, weight: .semibold))
                        .foregroundStyle(CanopyColor.text)
                        .lineLimit(1)
                    if let current = thought.folderPath.first {
                        Text("In \(current)")
                            .font(.system(size: CanopyFont.sizeXs))
                            .foregroundStyle(CanopyColor.textSubtle)
                    } else {
                        Text("Uncategorized")
                            .font(.system(size: CanopyFont.sizeXs))
                            .foregroundStyle(CanopyColor.textSubtle)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}
