import Foundation

/// A pinned, VIRTUAL alias folder at the top of the Thoughts screen (spec 0026). These are pure
/// PROJECTIONS over the loaded thoughts, not real directories on disk: nothing is created for them, and
/// they cannot be renamed or deleted. Each opens a flat thought list computed by `TopLevelFolders`.
enum AliasFolder: String, CaseIterable, Hashable, Identifiable {
    /// Every thought (any folder + uncategorized), flat, honoring the current sort order.
    case allThoughts
    /// The most-recent thoughts by `createdAt`, newest first, capped at `TopLevelFolders.recentsLimit`.
    case recents

    var id: String { rawValue }

    /// The row / screen title.
    var title: String {
        switch self {
        case .allThoughts: return "All Thoughts"
        case .recents: return "Recents"
        }
    }

    /// The SF Symbol glyph for the alias row (visually distinct from a user folder's `folder.fill`).
    var systemImage: String {
        switch self {
        case .allThoughts: return "tray.full.fill"
        case .recents: return "clock.fill"
        }
    }
}

/// The pure, `Sendable` model for the redesigned Thoughts screen (spec 0026): the TOP LEVEL is folders
/// ONLY - two pinned alias folders (All Thoughts, Recents) then the user's folders - and a user folder or
/// an alias opens a FLAT list of thoughts. There are no loose thoughts and no interleaving at the top
/// level, and there is no nesting (one level deep).
///
/// Every projection here is a pure function over the already-loaded `[Thought]` (the driver loads every
/// thought with its `folderPath` off the main actor), so it is unit-testable and UI-free (no SwiftUI
/// import) and reusable by a future Watch target. This supersedes spec 0010's interleaved
/// folders-and-thoughts `FolderListModel` for the top-level and folder screens.
enum TopLevelFolders {
    /// How many thoughts the Recents alias shows: the 10 most recent, newest first (confirmed decision).
    static let recentsLimit = 10

    // MARK: - Alias projections (virtual folders)

    /// Every thought, flat (any folder + uncategorized), honoring `sortOrder`. This is the "All Thoughts"
    /// alias: a pure sort over the whole loaded list, ignoring `folderPath` entirely.
    static func allThoughts(_ thoughts: [Thought], sorted sortOrder: ThoughtSortOrder) -> [Thought] {
        sortOrder.sort(thoughts)
    }

    /// The most-recent `limit` thoughts by `createdAt`, NEWEST FIRST (the "Recents" alias). Independent of
    /// the chosen sort order - Recents is always newest-first by definition. Ties on `createdAt` fall to the
    /// stable id tie-break so the order is deterministic. Fewer than `limit` thoughts returns them all.
    static func recents(_ thoughts: [Thought], limit: Int = recentsLimit) -> [Thought] {
        let newestFirst = thoughts.sorted {
            ThoughtSortOrder.newest.areInIncreasingOrder(
                ThoughtSortOrder.sortKey(for: $0),
                ThoughtSortOrder.sortKey(for: $1)
            )
        }
        guard limit >= 0 else { return newestFirst }
        return Array(newestFirst.prefix(limit))
    }

    // MARK: - Uncategorized

    /// The thoughts NOT in any user folder (the `.md` files at the store root): those whose `folderPath`
    /// is empty. They appear in All Thoughts and Recents, but in no user folder. Honors `sortOrder`.
    static func uncategorized(_ thoughts: [Thought], sorted sortOrder: ThoughtSortOrder) -> [Thought] {
        sortOrder.sort(thoughts.filter { $0.folderPath.isEmpty })
    }

    // MARK: - User folders (one level, flattened over legacy nesting)

    /// The thoughts that belong to the top-level user folder `folderName`, FLATTENED over any legacy nested
    /// subtree (spec 0026): a thought whose `folderPath` STARTS WITH `folderName` counts, so a thought that
    /// lived in an old nested folder (`[folderName, "Q1"]`) still surfaces under its top-level folder. New
    /// nesting is not created; this only keeps old data visible. Honors `sortOrder`.
    static func folderThoughts(
        _ thoughts: [Thought],
        folder folderName: String,
        sorted sortOrder: ThoughtSortOrder
    ) -> [Thought] {
        sortOrder.sort(thoughts.filter { $0.folderPath.first == folderName })
    }

    /// The number of thoughts in a top-level user folder, counting the flattened legacy subtree (so an
    /// old nested thought is counted under its top-level folder). Pure so the row subtitle is testable.
    static func folderThoughtCount(_ thoughts: [Thought], folder folderName: String) -> Int {
        thoughts.reduce(into: 0) { count, thought in
            if thought.folderPath.first == folderName { count += 1 }
        }
    }

    /// A user-facing, correctly pluralized label for a folder's thought count: "No thoughts" / "1 thought"
    /// / "N thoughts". Kept here (not the row) so the pluralization boundaries are unit-testable.
    static func thoughtCountLabel(_ count: Int) -> String {
        switch count {
        case 0: return "No thoughts"
        case 1: return "1 thought"
        default: return "\(count) thoughts"
        }
    }

    /// The top-level user folders, ordered case-insensitively A-Z. The store reports the child folder
    /// names at the root (`folders(at: [])`); this passes them through with a stable A-Z order so the
    /// top-level list is deterministic. Kept as a seam (not inlined in the view) for symmetry and testing.
    static func userFolderNames(childFolderNames: [String]) -> [String] {
        childFolderNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
