import Foundation

/// One row in the folder-aware Thoughts list (spec 0010): either a child folder at the current path,
/// or a thought that lives directly at the current path. Folders and thoughts are INTERLEAVED into one
/// ordered list (not two sections), so a folder sorts among thoughts by the same key - a folder's "date"
/// is its newest thought anywhere underneath and its "title" is its name.
///
/// Hashable and Identifiable so the SwiftUI `List`/`ForEach` can diff rows; a folder's identity is its
/// full path, a thought's is its id.
enum FolderListItem: Identifiable, Hashable {
    /// A child folder: `name` is the folder's own name, `path` is its FULL path from the root
    /// (`current + [name]`) so tapping it navigates straight to that path.
    case folder(name: String, path: [String])
    /// A thought that lives directly at the current path.
    case thought(Thought)

    var id: String {
        switch self {
        case let .folder(_, path):
            // A path string that cannot collide with a thought id (which is a UUID with no "/"): join the
            // components so two folders with the same name under different parents stay distinct.
            return "folder:" + path.joined(separator: "/")
        case let .thought(thought):
            return "thought:" + thought.id.uuidString
        }
    }
}

/// Pure, `@MainActor` projection that turns the driver's flat thoughts list plus the child folder names
/// at a path into the ordered `[FolderListItem]` the Thoughts screen renders (spec 0010).
///
/// This is where the folder feature's list logic lives, kept out of the SwiftUI view so it is unit
/// testable: filter thoughts to the current path, build a `SortKey` for each folder and thought, and
/// interleave them by the chosen `ThoughtSortOrder` using the SHARED comparator - so folders and thoughts
/// order by one set of rules and there is no second copy of the ordering.
///
/// A folder's `SortKey`:
/// - `title` = its name,
/// - `date` = the newest thought ANYWHERE under it (recursively; `.distantPast` when it holds no thoughts),
/// - `tieBreak` = its name (folders have no id).
///
/// The model takes the already-loaded `allThoughts` (the driver loads every thought with its `folderPath`
/// off the main actor - we do not re-read disk) and the `childFolderNames` the store reported for the
/// current path, so the view can hand it exactly what it has.
@MainActor
enum FolderListModel {
    /// Build the ordered rows for `currentPath` from every thought in the tree and the child folder names
    /// reported by the store at that path. Thoughts are filtered to those whose `folderPath` EQUALS the
    /// current path; folders are the reported children with their newest-descendant date computed from
    /// `allThoughts`. Both are interleaved and sorted by `sortOrder` via the shared `SortKey` comparator.
    static func items(
        allThoughts: [Thought],
        childFolderNames: [String],
        currentPath: [String],
        sortOrder: ThoughtSortOrder
    ) -> [FolderListItem] {
        // Thoughts at exactly this path (not in a subfolder): those get a thought row here; deeper thoughts are
        // shown when the user navigates into the folder that contains them.
        let thoughtsHere = allThoughts.filter { $0.folderPath == currentPath }

        // Newest-descendant date for every folder in one pass over the thoughts (see `newestDates(...)`),
        // keyed by full path, so we do not rescan the thoughts once per child folder.
        let datesByPath = newestDates(in: allThoughts)

        // A keyed row pairs an item with the SortKey the shared comparator orders by, so folders and
        // thoughts go through one comparison.
        struct Keyed {
            let item: FolderListItem
            let key: ThoughtSortOrder.SortKey
        }

        // Partition child folders into non-empty (>=1 descendant thought) and empty. Empty folders have no
        // thought to date them; rather than lean on a `.distantPast` sentinel - which sinks them under
        // `.newest` but floats them under `.oldest` - we hold them out of the interleave entirely and
        // append them at the bottom, name-ordered, so they are ALWAYS last regardless of sort order.
        var nonEmptyFolderRows: [Keyed] = []
        var emptyFolderNames: [String] = []
        for name in childFolderNames {
            let childPath = currentPath + [name]
            if let date = datesByPath[childPath] {
                // A folder's title is its name and its tie-break is its name too (no id to fall back
                // on), so two same-named folders (impossible under one parent) still compare
                // deterministically.
                let key = ThoughtSortOrder.SortKey(title: name, date: date, tieBreak: name)
                nonEmptyFolderRows.append(Keyed(item: .folder(name: name, path: childPath), key: key))
            } else {
                emptyFolderNames.append(name)
            }
        }

        let thoughtRows: [Keyed] = thoughtsHere.map { thought in
            Keyed(item: .thought(thought), key: ThoughtSortOrder.sortKey(for: thought))
        }

        let interleaved = (nonEmptyFolderRows + thoughtRows)
            .sorted { sortOrder.areInIncreasingOrder($0.key, $1.key) }
            .map(\.item)

        // Empty folders last, name-ordered case-insensitively (A-Z), under every sort order.
        let emptyRows: [FolderListItem] = emptyFolderNames
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { .folder(name: $0, path: currentPath + [$0]) }

        return interleaved + emptyRows
    }

    /// The number of thoughts ANYWHERE under `folderPath` (the folder itself and every descendant folder):
    /// an HONEST descendant-thought count for a folder row's subtitle. Counts thoughts whose `folderPath` has
    /// `folderPath` as a prefix, so an empty folder - or one holding only empty subfolders - reads 0,
    /// unlike a subtitle inferred from thought paths that would miss empty subfolders.
    static func descendantThoughtCount(of folderPath: [String], in thoughts: [Thought]) -> Int {
        thoughts.reduce(into: 0) { count, thought in
            if hasPrefix(thought.folderPath, prefix: folderPath) { count += 1 }
        }
    }

    /// A user-facing, correctly pluralized label for a descendant-thought count: "No thoughts" / "1 thought" /
    /// "N thoughts". Kept in the model (not the row) so the pluralization boundaries are unit-testable.
    static func thoughtCountLabel(_ count: Int) -> String {
        switch count {
        case 0: return "No thoughts"
        case 1: return "1 thought"
        default: return "\(count) thoughts"
        }
    }

    /// The newest `createdAt` of any thought ANYWHERE under `folderPath` (the folder itself and every
    /// descendant folder), or `.distantPast` when the folder holds no thoughts at all. A convenience over
    /// `newestDates(in:)` for callers that want a single folder's date.
    static func newestDescendantDate(under folderPath: [String], in allThoughts: [Thought]) -> Date {
        newestDates(in: allThoughts)[folderPath] ?? .distantPast
    }

    /// Newest-descendant `createdAt` for every folder that holds at least one thought, keyed by full path,
    /// computed in ONE pass over the thoughts: each thought updates the max date for every prefix of its
    /// `folderPath` (each such prefix is an ancestor folder the thought is a descendant of). A folder that
    /// holds no thought never appears as a key (its date is absent, not `.distantPast`), so callers can
    /// tell "empty" from "dated `.distantPast`". Complexity is O(thoughts x path depth), not O(folders x
    /// thoughts).
    static func newestDates(in allThoughts: [Thought]) -> [[String]: Date] {
        var newest: [[String]: Date] = [:]
        for thought in allThoughts {
            // Update every ancestor prefix (folderPath[0..<k] for k in 1...count). The empty prefix
            // (root) is intentionally skipped: the root is not a folder row.
            if thought.folderPath.isEmpty { continue }
            for depth in 1...thought.folderPath.count {
                let prefix = Array(thought.folderPath.prefix(depth))
                if let current = newest[prefix] {
                    if thought.createdAt > current { newest[prefix] = thought.createdAt }
                } else {
                    newest[prefix] = thought.createdAt
                }
            }
        }
        return newest
    }

    /// Whether a thought at `thoughtPath` lives anywhere in `folderPath`'s subtree (spec 0015): `folderPath`
    /// is a prefix of `thoughtPath`, so a thought directly in the folder OR in any descendant folder counts.
    /// Exposed so a folder-swipe play queue can gather a folder's whole subtree with the same
    /// prefix rule the descendant-thought count uses.
    static func isDescendant(_ thoughtPath: [String], of folderPath: [String]) -> Bool {
        hasPrefix(thoughtPath, prefix: folderPath)
    }

    /// Whether `path` starts with `prefix` (so a thought at `path` lives under the folder `prefix`). A
    /// path is under itself, so a thought directly in the folder counts as a descendant.
    private static func hasPrefix(_ path: [String], prefix: [String]) -> Bool {
        guard path.count >= prefix.count else { return false }
        return Array(path.prefix(prefix.count)) == prefix
    }
}
