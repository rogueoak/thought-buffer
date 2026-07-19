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
}
