import SwiftUI

/// A multi-select picker to move existing thoughts INTO a folder (feedback 0026, item 6). It is the inverse
/// of `MoveToFolderSheet` (which moves ONE thought TO a chosen folder): here the destination folder is fixed
/// (the empty folder the user is viewing) and the user selects WHICH thoughts to pull in. It lists ALL
/// thoughts across the store - already-in-this-folder ones are excluded, since moving them here is a no-op -
/// with a checkmark toggle per row, and a "Move" action that re-files every selected thought into the folder.
///
/// Moving is the same re-save-with-a-new-`folderPath` the rest of the app uses (the store relocates each
/// thought's `.md` and sibling `.m4a`), so a recorded thought keeps its recording.
///
/// A search field (feedback 0029, item 3) filters the candidate list live by title/text so a thought is
/// easy to find in a long list. It reuses `ThoughtSearch.results(in:query:)` - the SAME pure matcher the
/// global thought search uses - so the matching rules are not duplicated. Selections are a `Set<UUID>`
/// keyed on id, so they stay stable across filtering: filtering a thought out of view never drops its
/// selection, and re-showing it reflects its prior checkmark.
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
    /// The live filter query (feedback 0029, item 3), matched against candidate title/text.
    @State private var query = ""

    /// Thoughts that are NOT already in this folder (moving those here is a no-op), so only movable ones show.
    private var candidates: [Thought] {
        allThoughts.filter { $0.folderPath.first != folderName }
    }

    /// The candidates narrowed by the live `query` (feedback 0029, item 3), through the shared pure
    /// `ThoughtSearch` matcher (title OR any paragraph, case- and diacritic-insensitive). An empty query
    /// returns every candidate, so the field starts showing the full list.
    private var filteredCandidates: [Thought] {
        ThoughtSearch.results(in: candidates, query: query)
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
                let rows = filteredCandidates
                if rows.isEmpty {
                    Text("No thought matches \"\(query.trimmingCharacters(in: .whitespacesAndNewlines))\".")
                        .font(.system(size: CanopyFont.sizeSm))
                        .foregroundStyle(CanopyColor.textMuted)
                } else {
                    ForEach(rows) { thought in
                        row(for: thought)
                    }
                }
            }
            .listStyle(.insetGrouped)
            // Filter the candidates live (feedback 0029, item 3). `.searchable` keeps ONE List whose rows
            // filter - the field never swaps the list host, so focus is stable within the sheet.
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search thoughts")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
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
