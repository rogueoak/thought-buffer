import Foundation

/// One row in the folder-aware Thoughts list (spec 0010): either a child folder at the current path,
/// or a note that lives directly at the current path. Folders and notes are INTERLEAVED into one
/// ordered list (not two sections), so a folder sorts among notes by the same key - a folder's "date"
/// is its newest note anywhere underneath and its "title" is its name.
///
/// Hashable and Identifiable so the SwiftUI `List`/`ForEach` can diff rows; a folder's identity is its
/// full path, a note's is its id.
enum FolderListItem: Identifiable, Hashable {
    /// A child folder: `name` is the folder's own name, `path` is its FULL path from the root
    /// (`current + [name]`) so tapping it navigates straight to that path.
    case folder(name: String, path: [String])
    /// A note that lives directly at the current path.
    case note(Note)

    var id: String {
        switch self {
        case let .folder(_, path):
            // A path string that cannot collide with a note id (which is a UUID with no "/"): join the
            // components so two folders with the same name under different parents stay distinct.
            return "folder:" + path.joined(separator: "/")
        case let .note(note):
            return "note:" + note.id.uuidString
        }
    }
}

/// Pure, `@MainActor` projection that turns the driver's flat notes list plus the child folder names
/// at a path into the ordered `[FolderListItem]` the Thoughts screen renders (spec 0010).
///
/// This is where the folder feature's list logic lives, kept out of the SwiftUI view so it is unit
/// testable: filter notes to the current path, build a `SortKey` for each folder and note, and
/// interleave them by the chosen `NoteSortOrder` using the SHARED comparator - so folders and notes
/// order by one set of rules and there is no second copy of the ordering.
///
/// A folder's `SortKey`:
/// - `title` = its name,
/// - `date` = the newest note ANYWHERE under it (recursively; `.distantPast` when it holds no notes),
/// - `tieBreak` = its name (folders have no id).
///
/// The model takes the already-loaded `allNotes` (the driver loads every note with its `folderPath`
/// off the main actor - we do not re-read disk) and the `childFolderNames` the store reported for the
/// current path, so the view can hand it exactly what it has.
@MainActor
enum FolderListModel {
    /// Build the ordered rows for `currentPath` from every note in the tree and the child folder names
    /// reported by the store at that path. Notes are filtered to those whose `folderPath` EQUALS the
    /// current path; folders are the reported children with their newest-descendant date computed from
    /// `allNotes`. Both are interleaved and sorted by `sortOrder` via the shared `SortKey` comparator.
    static func items(
        allNotes: [Note],
        childFolderNames: [String],
        currentPath: [String],
        sortOrder: NoteSortOrder
    ) -> [FolderListItem] {
        // Notes at exactly this path (not in a subfolder): those get a note row here; deeper notes are
        // shown when the user navigates into the folder that contains them.
        let notesHere = allNotes.filter { $0.folderPath == currentPath }

        // Newest-descendant date for every folder in one pass over the notes (see `newestDates(...)`),
        // keyed by full path, so we do not rescan the notes once per child folder.
        let datesByPath = newestDates(in: allNotes)

        // A keyed row pairs an item with the SortKey the shared comparator orders by, so folders and
        // notes go through one comparison.
        struct Keyed {
            let item: FolderListItem
            let key: NoteSortOrder.SortKey
        }

        // Partition child folders into non-empty (>=1 descendant note) and empty. Empty folders have no
        // note to date them; rather than lean on a `.distantPast` sentinel - which sinks them under
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
                let key = NoteSortOrder.SortKey(title: name, date: date, tieBreak: name)
                nonEmptyFolderRows.append(Keyed(item: .folder(name: name, path: childPath), key: key))
            } else {
                emptyFolderNames.append(name)
            }
        }

        let noteRows: [Keyed] = notesHere.map { note in
            Keyed(item: .note(note), key: NoteSortOrder.sortKey(for: note))
        }

        let interleaved = (nonEmptyFolderRows + noteRows)
            .sorted { sortOrder.areInIncreasingOrder($0.key, $1.key) }
            .map(\.item)

        // Empty folders last, name-ordered case-insensitively (A-Z), under every sort order.
        let emptyRows: [FolderListItem] = emptyFolderNames
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { .folder(name: $0, path: currentPath + [$0]) }

        return interleaved + emptyRows
    }

    /// The number of notes ANYWHERE under `folderPath` (the folder itself and every descendant folder):
    /// an HONEST descendant-note count for a folder row's subtitle. Counts notes whose `folderPath` has
    /// `folderPath` as a prefix, so an empty folder - or one holding only empty subfolders - reads 0,
    /// unlike a subtitle inferred from note paths that would miss empty subfolders.
    static func descendantNoteCount(of folderPath: [String], in notes: [Note]) -> Int {
        notes.reduce(into: 0) { count, note in
            if hasPrefix(note.folderPath, prefix: folderPath) { count += 1 }
        }
    }

    /// A user-facing, correctly pluralized label for a descendant-note count: "No notes" / "1 note" /
    /// "N notes". Kept in the model (not the row) so the pluralization boundaries are unit-testable.
    static func noteCountLabel(_ count: Int) -> String {
        switch count {
        case 0: return "No notes"
        case 1: return "1 note"
        default: return "\(count) notes"
        }
    }

    /// The newest `createdAt` of any note ANYWHERE under `folderPath` (the folder itself and every
    /// descendant folder), or `.distantPast` when the folder holds no notes at all. A convenience over
    /// `newestDates(in:)` for callers that want a single folder's date.
    static func newestDescendantDate(under folderPath: [String], in allNotes: [Note]) -> Date {
        newestDates(in: allNotes)[folderPath] ?? .distantPast
    }

    /// Newest-descendant `createdAt` for every folder that holds at least one note, keyed by full path,
    /// computed in ONE pass over the notes: each note updates the max date for every prefix of its
    /// `folderPath` (each such prefix is an ancestor folder the note is a descendant of). A folder that
    /// holds no note never appears as a key (its date is absent, not `.distantPast`), so callers can
    /// tell "empty" from "dated `.distantPast`". Complexity is O(notes x path depth), not O(folders x
    /// notes).
    static func newestDates(in allNotes: [Note]) -> [[String]: Date] {
        var newest: [[String]: Date] = [:]
        for note in allNotes {
            // Update every ancestor prefix (folderPath[0..<k] for k in 1...count). The empty prefix
            // (root) is intentionally skipped: the root is not a folder row.
            if note.folderPath.isEmpty { continue }
            for depth in 1...note.folderPath.count {
                let prefix = Array(note.folderPath.prefix(depth))
                if let current = newest[prefix] {
                    if note.createdAt > current { newest[prefix] = note.createdAt }
                } else {
                    newest[prefix] = note.createdAt
                }
            }
        }
        return newest
    }

    /// Whether `path` starts with `prefix` (so a note at `path` lives under the folder `prefix`). A
    /// path is under itself, so a note directly in the folder counts as a descendant.
    private static func hasPrefix(_ path: [String], prefix: [String]) -> Bool {
        guard path.count >= prefix.count else { return false }
        return Array(path.prefix(prefix.count)) == prefix
    }
}
