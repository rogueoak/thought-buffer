import Foundation

/// SwiftUI projection over `ThoughtStoreDriver`: a thin `@MainActor ObservableObject` that republishes
/// the driver's thoughts list so the Stream list view can bind to it, and forwards start/stop/reload.
///
/// The actual load and iCloud-observer wiring lives in the headless `ThoughtStoreDriver`, so the same
/// behavior can be driven without SwiftUI (a future CarPlay/Siri session). This type exists only to
/// give a view an `ObservableObject` to observe; it holds no logic of its own beyond mirroring the
/// driver's `@Published` state.
@MainActor
final class StreamFeed: ObservableObject {
    /// The thoughts to render, newest first. Empty until the first load completes. Mirrors the driver.
    @Published private(set) var thoughts: [Thought] = []
    /// True once an initial load has finished, so the view can tell "empty" from "not loaded yet".
    @Published private(set) var didLoad = false
    /// Set when a delete failed, so the view can show a brief, non-blocking message. Mirrors the
    /// driver; cleared via `clearDeleteFailure()` once the view has surfaced it.
    @Published private(set) var deleteFailed = false
    /// Monotonic counter bumped every time the driver republishes its thoughts list. Mirrors the driver;
    /// a view keys a refresh on it to catch republishes that leave the thought count unchanged (a rename,
    /// a move between two existing folders, or an iCloud-synced empty folder).
    @Published private(set) var reloadGeneration = 0

    private let driver: ThoughtStoreDriver

    init(store: ThoughtStoring, observer: UbiquitousThoughtObserving? = nil) {
        self.driver = ThoughtStoreDriver(store: store, observer: observer)
        driver.onStateChange = { [weak self] in self?.mirror() }
    }

    /// Do the initial load, then wire the iCloud observer (if any). Call from the view's `.task`.
    func start() async { await driver.start() }

    /// Tear down the observer and drop the change closure. Call from the view's task cancellation.
    func stop() { driver.stop() }

    /// Reload the list off the main thread. Call after a dictation session saves.
    func reload() async { await driver.reload() }

    /// Soft-delete a thought (spec 0020): move it to the store's trash, then reload. Returns a
    /// `DeletedThought` token to register with the UndoManager and the in-app undo affordance, or nil when
    /// the delete failed / there was nothing to delete. A failure surfaces via `deleteFailed`.
    @discardableResult
    func delete(id: UUID) async -> DeletedThought? { await driver.delete(id: id) }

    /// Restore a soft-deleted thought (spec 0020) - undo a delete - then reload so it reappears.
    func restore(_ token: DeletedThought) async { await driver.restore(token) }

    /// Permanently remove a soft-deleted thought's trashed files (spec 0020): commit the delete when its
    /// undo window closes.
    func purge(_ token: DeletedThought) async { await driver.purge(token) }

    /// Empty the whole trash (spec 0020): an opportunistic launch-time sweep, called once on start.
    func purgeAllTrash() async { await driver.purgeAllTrash() }

    /// Clear a surfaced delete-failure message once the view has shown it.
    func clearDeleteFailure() { driver.clearDeleteFailure(); mirror() }

    // MARK: - Folders (spec 0010)

    /// The child folder names directly under `path` (empty = top level), for building a folder screen.
    func childFolders(at path: [String]) async -> [String] { await driver.childFolders(at: path) }

    /// Create a folder under `path`; returns the sanitized name used, or nil when rejected/empty.
    @discardableResult
    func createFolder(named name: String, at path: [String]) async -> String? {
        await driver.createFolder(named: name, at: path)
    }

    /// Rename the folder at `path`; returns the sanitized new name, or nil when rejected/conflicting.
    @discardableResult
    func renameFolder(at path: [String], to newName: String) async -> String? {
        await driver.renameFolder(at: path, to: newName)
    }

    /// Delete the folder at `path` and everything inside it (cascade), then reload.
    func deleteFolder(at path: [String]) async { await driver.deleteFolder(at: path) }

    /// Move a thought into `folderPath` (empty = top level) by re-saving it there, then reload.
    func move(_ thought: Thought, to folderPath: [String]) async { await driver.move(thought, to: folderPath) }

    /// Copy the driver's current state into the published properties so observers refresh.
    private func mirror() {
        thoughts = driver.thoughts
        didLoad = driver.didLoad
        deleteFailed = driver.deleteFailed
        reloadGeneration = driver.reloadGeneration
    }
}
