import Foundation

/// Pure reconciliation for the split view's DETAIL column selection (spec 0022). The detail column shows
/// the selected thought; two events can leave it STALE, and both are decided here so the rule is unit-tested
/// rather than trapped in view state:
///
/// - A thought open in the detail column is DELETED: keeping it shown lets the user read / edit / resume a
///   thought that no longer exists. When the deleted id is the shown one, the selection must clear.
/// - The user switches the SIDEBAR folder: the previously-open thought belonged to the old folder's context,
///   so opening a different folder clears the detail (a fresh folder has no thought selected yet).
///
/// No SwiftUI import - operates on ids so it stays reusable and provable without UI.
enum SplitDetailReconcile {
    /// Whether a delete of `deletedId` must clear a detail selection currently showing `shownThoughtId`.
    /// True only when they match; a delete of some OTHER thought (e.g. a swipe in the list) leaves the open
    /// thought alone. `shownThoughtId` is nil when the detail column shows the placeholder or a not-yet-saved
    /// new-thought draft (which has no persisted id to delete), so nothing clears.
    static func deleteClearsSelection(deletedId: UUID, shownThoughtId: UUID?) -> Bool {
        guard let shownThoughtId else { return false }
        return deletedId == shownThoughtId
    }

    /// Whether the split view's CONTENT-column subject still exists after the top-level folder names reload
    /// (spec 0026). The content column shows the selected `FolderSubject`'s flat thought list; renaming or
    /// deleting the shown user folder FROM THE SIDEBAR leaves the content column pointed at a folder that no
    /// longer exists, so `TopLevelFolders.thoughts(for:)` returns `[]` and the column silently shows an empty
    /// list instead of reverting to the placeholder. This is the sidebar analogue of `deleteClearsSelection`:
    ///
    /// - an ALIAS subject (All Thoughts / Recents) always survives (aliases are virtual, never renamed/deleted),
    /// - a USER FOLDER subject survives only while its name is still among the loaded top-level folder names,
    /// - no selection (`nil`) trivially survives (nothing to clear).
    ///
    /// The caller clears `selectedSubject` (and the dependent detail selection) when this returns false.
    static func contentSubjectSurvives(_ subject: FolderSubject?, inFolderNames folderNames: [String]) -> Bool {
        switch subject {
        case nil, .alias:
            return true
        case let .userFolder(name):
            return folderNames.contains(name)
        }
    }
}
