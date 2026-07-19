import Foundation

/// A lightweight token for a note that was SOFT-deleted (spec 0020): its files were moved into the
/// store's trash directory rather than removed, so the delete can be undone. It carries everything the
/// store needs to `restore(_:)` the note to where it came from, or to `purge(_:)` it permanently.
///
/// It is a value type (no store reference) so it can be handed to the UndoManager, the in-app undo
/// affordance, and a launch-time purge sweep alike. The filenames are the trashed file's LAST path
/// components (`<id>.md`, `<id>.m4a`), which live under the store's `.trash/<id>/` directory; the
/// `folderPath` is where the note lived before deletion, used to move it back on restore.
struct DeletedNote: Equatable, Sendable {
    /// The deleted note's id, the stable key for its trashed files (`<id>.md` and optional `<id>.m4a`)
    /// and for the per-note trash subdirectory that holds them.
    let id: UUID
    /// The folder path the note lived in before deletion, so `restore(_:)` returns it to the same
    /// place. Empty means it was a top-level note. If that folder no longer exists at restore time,
    /// the note lands at root instead (see `restoredToRoot` on the restore result).
    let formerFolderPath: [String]
    /// The trashed note file's name (`<id>.md`). Stored explicitly rather than recomputed so the token
    /// is self-describing and the restore never guesses the extension.
    let noteFilename: String
    /// The trashed audio file's name (`<id>.m4a`) when the note carried a recording, else nil. Restore
    /// moves it back beside the note; purge removes it.
    let audioFilename: String?
}

/// The outcome of a `restore(_:)`: whether the note landed back in its original folder or, because that
/// folder no longer exists, at the root (spec 0020 requires restore to never fail on a missing folder).
struct RestoredNote: Equatable, Sendable {
    /// The note's id, restored and now readable again through the store.
    let id: UUID
    /// The folder path the note was actually restored INTO. Equals the token's `formerFolderPath` when
    /// that folder still exists, or `[]` (root) when it was gone - in which case `landedAtRoot` is true.
    let folderPath: [String]
    /// True when the original folder was missing at restore time, so the note was placed at root rather
    /// than failing. The caller can surface this ("restored to your notes") if it wants to.
    let landedAtRoot: Bool
}
