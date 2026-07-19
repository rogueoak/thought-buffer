import Foundation

/// Coordinates a note's UNDOABLE delete (spec 0020): it runs the soft-delete through the feed, registers
/// the delete with the system `UndoManager` (so the Shake to Undo gesture offers "Undo Delete"), shows
/// the in-app "Note deleted - Undo" affordance, and PURGES the trashed files once the undo window closes.
///
/// A `@MainActor ObservableObject` owned by the composition root (`StreamListView`) so ONE controller
/// serves every delete entry point - the list-row swipe, the list-row context menu, and the note-detail
/// "..." menu - and the undo affordance always shows at the list level (a delete from detail dismisses
/// back to the list, where the chip is visible). It holds no SwiftUI; the view binds to its published
/// state and passes it a live `UndoManager` from the environment.
@MainActor
final class NoteDeletionController: ObservableObject {
    /// The most recent delete's token while its undo window is open, else nil. Published so the view can
    /// show the affordance and re-arm its auto-hide on each new delete.
    @Published private(set) var pending: DeletedNote?
    /// A monotonic counter bumped on every delete, so the affordance's lifecycle-tied auto-hide/purge
    /// timer re-arms on a rapid second delete instead of the first delete's timer purging the second.
    @Published private(set) var deleteTrigger = 0

    private let feed: StreamFeed
    /// The system UndoManager for the active scene, set from the SwiftUI `@Environment(\.undoManager)`
    /// so a shake routes to `undo()`/redo. Weak: the manager is owned by the responder chain, not us.
    weak var undoManager: UndoManager?

    init(feed: StreamFeed) {
        self.feed = feed
    }

    /// Soft-delete the note behind `id` and make it undoable. Moves its files to the store trash, then
    /// registers the delete with the `UndoManager` (undo -> restore, redo -> re-delete) named "Delete"
    /// so the system prompt reads "Undo Delete", and shows the in-app affordance. Does nothing user-
    /// visible beyond the delete when the store returned no token (nothing trashed, or the delete failed
    /// - the feed surfaces that separately via `deleteFailed`).
    func delete(id: UUID) async {
        // Committing any previously pending delete first: a new delete starts a fresh undo window, so the
        // prior one is past its chance to be undone in-app. (Shake could still target it until the
        // UndoManager coalesces, but the in-app single-step affordance only tracks the latest.)
        if let previous = pending {
            await feed.purge(previous)
            pending = nil
        }
        guard let token = await feed.delete(id: id) else { return }
        registerUndo(for: token)
        pending = token
        deleteTrigger &+= 1
    }

    /// Undo the pending delete: restore the note (to root if its folder is gone) and clear the pending
    /// window so its timer no longer purges. Called by the in-app Undo button and by the UndoManager on a
    /// shake. Registers the inverse (a redo that re-deletes) so shake redo works too.
    func undo() async {
        guard let token = pending else { return }
        pending = nil
        await feed.restore(token)
        registerRedo(for: token)
    }

    /// Close the undo window: PURGE the pending trashed files permanently (commit the delete) and clear
    /// the pending state. Called when the in-app affordance's timer elapses. Idempotent - a no-op once
    /// the window has already been closed (by an undo or a following delete).
    func commitWindow() async {
        guard let token = pending else { return }
        pending = nil
        await feed.purge(token)
    }

    /// Opportunistically empty the store trash on launch (spec 0020): committed deletes from a prior run,
    /// or trash a crash left behind, are purged since they have no pending undo. Safe because a pending
    /// undo only exists within one run's lifetime (the token lives in memory, not on disk).
    func purgeOrphanedTrashOnLaunch() async {
        await feed.purgeAllTrash()
    }

    // MARK: - UndoManager wiring

    /// Register the delete with the system UndoManager so Shake to Undo offers "Undo Delete". The undo
    /// operation restores the note; when the undo itself is registered, its inverse (a redo) re-deletes,
    /// so shake redo re-applies the delete. Named "Delete" so the system prompt reads "Undo Delete".
    private func registerUndo(for token: DeletedNote) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            Task { @MainActor in await target.undoDelete(token) }
        }
        undoManager.setActionName("Delete")
    }

    /// The UndoManager's undo action: restore the note (mirrors the in-app `undo()`), and if this note is
    /// the one the in-app affordance is tracking, clear it so its timer stops purging.
    private func undoDelete(_ token: DeletedNote) async {
        if pending == token { pending = nil }
        await feed.restore(token)
        registerRedo(for: token)
    }

    /// Register the redo (re-delete) so a shake redo re-applies the delete. Re-deleting through the store
    /// soft-deletes again, and re-arms the whole undo cycle (its own undo restores once more).
    private func registerRedo(for token: DeletedNote) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            Task { @MainActor in await target.redoDelete(token) }
        }
        undoManager.setActionName("Delete")
    }

    /// The UndoManager's redo action: re-delete the note (soft-delete it again) and re-register the undo,
    /// so the undo/redo pair keeps working across repeated shakes.
    private func redoDelete(_ token: DeletedNote) async {
        _ = await feed.delete(id: token.id)
        registerUndo(for: token)
        pending = token
        deleteTrigger &+= 1
    }
}
