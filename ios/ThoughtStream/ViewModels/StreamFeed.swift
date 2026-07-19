import Foundation

/// SwiftUI projection over `NoteStoreDriver`: a thin `@MainActor ObservableObject` that republishes
/// the driver's notes list so the Stream list view can bind to it, and forwards start/stop/reload.
///
/// The actual load and iCloud-observer wiring lives in the headless `NoteStoreDriver`, so the same
/// behavior can be driven without SwiftUI (a future CarPlay/Siri session). This type exists only to
/// give a view an `ObservableObject` to observe; it holds no logic of its own beyond mirroring the
/// driver's `@Published` state.
@MainActor
final class StreamFeed: ObservableObject {
    /// The notes to render, newest first. Empty until the first load completes. Mirrors the driver.
    @Published private(set) var notes: [Note] = []
    /// True once an initial load has finished, so the view can tell "empty" from "not loaded yet".
    @Published private(set) var didLoad = false
    /// Set when a delete failed, so the view can show a brief, non-blocking message. Mirrors the
    /// driver; cleared via `clearDeleteFailure()` once the view has surfaced it.
    @Published private(set) var deleteFailed = false

    private let driver: NoteStoreDriver

    init(store: NoteStoring, observer: UbiquitousNoteObserving? = nil) {
        self.driver = NoteStoreDriver(store: store, observer: observer)
        driver.onStateChange = { [weak self] in self?.mirror() }
    }

    /// Do the initial load, then wire the iCloud observer (if any). Call from the view's `.task`.
    func start() async { await driver.start() }

    /// Tear down the observer and drop the change closure. Call from the view's task cancellation.
    func stop() { driver.stop() }

    /// Reload the list off the main thread. Call after a dictation session saves.
    func reload() async { await driver.reload() }

    /// Delete a note (and its sibling recording) through the store, then reload. Call from the
    /// list's swipe-to-delete action. A failure surfaces via `deleteFailed`.
    func delete(id: UUID) async { await driver.delete(id: id) }

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

    /// Move a note into `folderPath` (empty = top level) by re-saving it there, then reload.
    func move(_ note: Note, to folderPath: [String]) async { await driver.move(note, to: folderPath) }

    /// Copy the driver's current state into the published properties so observers refresh.
    private func mirror() {
        notes = driver.notes
        didLoad = driver.didLoad
        deleteFailed = driver.deleteFailed
    }
}
