import Foundation

/// Headless owner of the thoughts list and its live-update wiring, with no SwiftUI or
/// `ObservableObject` dependency. Loads thoughts through the injected `ThoughtStoring` off the main
/// thread (the iCloud store's `loadAll()` is a chain of coordinated reads that can block on the
/// sync daemon) and, when an iCloud observer is present, refreshes on external edits / synced-in
/// files.
///
/// Split out from `StreamFeed` so any consumer can drive the same load/observe behavior - the
/// SwiftUI Stream list today, and a future headless CarPlay/Siri session tomorrow - without
/// pulling in `@MainActor ObservableObject`. `StreamFeed` is a thin main-actor projection over
/// this type; keep the actual load/observe logic here.
///
/// Main-actor isolated: the thoughts list is main-actor state and the observer's `onChange` is
/// documented to fire on the main actor, so callers observe a single consistent thread.
@MainActor
final class ThoughtStoreDriver {
    /// The thoughts to render, newest first. Empty until the first load completes.
    private(set) var thoughts: [Thought] = []
    /// True once an initial load has finished, so a consumer can tell "empty" from "not loaded yet".
    private(set) var didLoad = false
    /// Set when a delete failed (the coordinated removal threw), so a projection can surface a
    /// brief, non-blocking message. Cleared on the next successful delete or when the consumer
    /// dismisses it. The thought stays visible (the reload re-reflects the true on-disk state).
    private(set) var deleteFailed = false
    /// Monotonic counter bumped EVERY time the thoughts list is (re)published - on each `reload()` and on
    /// the observer-driven refresh path. A change token that changes even when the thought COUNT does not
    /// (a rename, a move between two existing folders, or an iCloud-synced empty folder), so a consumer
    /// that keys a refresh on it catches every republish, not just count changes.
    private(set) var reloadGeneration = 0

    /// Called after any state change (a completed reload) so a projection can republish. Set by the
    /// owner; fires on the main actor.
    var onStateChange: (() -> Void)?

    private let store: ThoughtStoring
    private let observer: UbiquitousThoughtObserving?
    private var started = false

    init(store: ThoughtStoring, observer: UbiquitousThoughtObserving? = nil) {
        self.store = store
        self.observer = observer
    }

    /// Do the initial load, then wire the iCloud observer (if any) to reload on change. Idempotent:
    /// starting twice does not double-wire the observer.
    func start() async {
        await reload()
        guard let observer, !started else { return }
        started = true
        observer.onChange = { [weak self] in
            Task { await self?.reload() }
        }
        observer.start()
    }

    /// Tear down the observer and drop the change closure, so an app-lifetime observer never holds
    /// a stale reference back into a gone driver.
    func stop() {
        guard started else { return }
        started = false
        observer?.onChange = nil
        observer?.stop()
    }

    /// Soft-delete a thought (spec 0020): move its files into the store's trash rather than removing them,
    /// then reload so the list reflects the removal. Returns a `DeletedThought` token the caller registers
    /// with the UndoManager and the in-app undo affordance, or nil when the delete failed / the thought had
    /// no file. The delete runs on a detached task like the load, because the iCloud store coordinates
    /// the file move. A failure is SURFACED (not swallowed): `deleteFailed` is set so the projection can
    /// show a brief, non-blocking message, and the reload re-reflects the true on-disk state.
    @discardableResult
    func delete(id: UUID) async -> DeletedThought? {
        let result: Result<DeletedThought?, Error> = await Task.detached(priority: .userInitiated) { [store] in
            do {
                return .success(try store.softDelete(id: id))
            } catch {
                return .failure(error)
            }
        }.value
        let token: DeletedThought?
        switch result {
        case let .success(deleted):
            deleteFailed = false
            token = deleted
        case .failure:
            deleteFailed = true
            token = nil
        }
        await reload()
        return token
    }

    /// Restore a soft-deleted thought (spec 0020): move its trashed files back (to root if the original
    /// folder is gone), then reload so it reappears. Runs on a detached task like the delete. A failure
    /// is swallowed (the reload re-reflects the true state); restore is best-effort undo.
    func restore(_ token: DeletedThought) async {
        await Task.detached(priority: .userInitiated) { [store] in
            _ = try? store.restore(token)
        }.value
        await reload()
    }

    /// Permanently remove a soft-deleted thought's trashed files (spec 0020): commit the delete once the
    /// undo window closes. No reload needed - the thought already left the list on delete. Detached because
    /// the iCloud store coordinates the removal.
    func purge(_ token: DeletedThought) async {
        await Task.detached(priority: .userInitiated) { [store] in
            try? store.purge(token)
        }.value
    }

    /// Empty the whole trash (spec 0020): an opportunistic launch-time sweep of any tokens with no
    /// pending undo (a delete committed before the app was killed, or trash left by a crash). Detached
    /// because the iCloud store coordinates the removal. No reload - trashed files are not in the list.
    func purgeAllTrash() async {
        await Task.detached(priority: .userInitiated) { [store] in
            try? store.purgeAllTrash()
        }.value
    }

    /// Clear a surfaced delete-failure message once the consumer has shown it.
    func clearDeleteFailure() {
        deleteFailed = false
    }

    // MARK: - Folders (spec 0010)

    /// The child folder names directly under `path` (empty `path` = the top level), sorted A-Z by the
    /// store. Read off a detached task like the load, because the iCloud store coordinates the
    /// directory walk. Used by the view to build the current folder screen's rows.
    func childFolders(at path: [String]) async -> [String] {
        await Task.detached(priority: .userInitiated) { [store] in
            store.folders(at: path)
        }.value
    }

    /// Create a folder under `path`, returning the sanitized name used, or nil when the name sanitizes
    /// to empty (the caller shows a "name rejected" message). Reloads so a new empty folder that holds
    /// thoughts-to-be is reflected; a fresh empty folder itself is picked up by the view's own
    /// `childFolders(at:)` refresh. A throw surfaces as `deleteFailed` is NOT reused here - folder
    /// failures are rare and the caller can re-try; we return the result so the caller decides.
    @discardableResult
    func createFolder(named name: String, at path: [String]) async -> String? {
        let result = await Task.detached(priority: .userInitiated) { [store] in
            try? store.createFolder(named: name, at: path)
        }.value
        await reload()
        return result ?? nil
    }

    /// Rename the folder at `path` to `newName`, returning the sanitized new name, or nil when the name
    /// sanitizes to empty OR conflicts with an existing sibling (the store returns nil for both, and
    /// the caller surfaces a conflict/rejected message). Reloads so foldered thoughts reflect the new
    /// location.
    @discardableResult
    func renameFolder(at path: [String], to newName: String) async -> String? {
        let result = await Task.detached(priority: .userInitiated) { [store] in
            try? store.renameFolder(at: path, to: newName)
        }.value
        await reload()
        return result ?? nil
    }

    /// Delete the folder at `path` and everything inside it (a destructive cascade), then reload.
    func deleteFolder(at path: [String]) async {
        await Task.detached(priority: .userInitiated) { [store] in
            try? store.deleteFolder(at: path)
        }.value
        await reload()
    }

    /// Move a thought to `folderPath` by re-saving it there. The store relocates the thought's `.md` and its
    /// sibling `.m4a`, so a recorded thought keeps its recording. Reloads so the list reflects the move.
    func move(_ thought: Thought, to folderPath: [String]) async {
        await Task.detached(priority: .userInitiated) { [store] in
            // Discard the saved URL: this is a fire-and-forget re-file, the reload below reflects the move.
            _ = try? store.save(thought.withFolderPath(folderPath))
        }.value
        await reload()
    }

    /// Reload the list. `loadAll()` runs on a detached task (it can block on iCloud coordination);
    /// only the assignment touches this main-actor state, then `onStateChange` fires.
    func reload() async {
        let loaded = await Task.detached(priority: .userInitiated) { [store] in
            store.loadAll()
        }.value
        thoughts = loaded
        didLoad = true
        // Bump on every republish so a count-insensitive change (rename, move between existing
        // folders, synced-in empty folder) still advances the token the view refreshes on.
        reloadGeneration &+= 1
        onStateChange?()
    }
}
