import Foundation

/// Headless owner of the notes list and its live-update wiring, with no SwiftUI or
/// `ObservableObject` dependency. Loads notes through the injected `NoteStoring` off the main
/// thread (the iCloud store's `loadAll()` is a chain of coordinated reads that can block on the
/// sync daemon) and, when an iCloud observer is present, refreshes on external edits / synced-in
/// files.
///
/// Split out from `StreamFeed` so any consumer can drive the same load/observe behavior - the
/// SwiftUI Stream list today, and a future headless CarPlay/Siri session tomorrow - without
/// pulling in `@MainActor ObservableObject`. `StreamFeed` is a thin main-actor projection over
/// this type; keep the actual load/observe logic here.
///
/// Main-actor isolated: the notes list is main-actor state and the observer's `onChange` is
/// documented to fire on the main actor, so callers observe a single consistent thread.
@MainActor
final class NoteStoreDriver {
    /// The notes to render, newest first. Empty until the first load completes.
    private(set) var notes: [Note] = []
    /// True once an initial load has finished, so a consumer can tell "empty" from "not loaded yet".
    private(set) var didLoad = false

    /// Called after any state change (a completed reload) so a projection can republish. Set by the
    /// owner; fires on the main actor.
    var onStateChange: (() -> Void)?

    private let store: NoteStoring
    private let observer: UbiquitousNoteObserving?
    private var started = false

    init(store: NoteStoring, observer: UbiquitousNoteObserving? = nil) {
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

    /// Delete a note through the store (which also removes its sibling audio recording), then reload
    /// the feed so the list reflects the removal. The delete runs on a detached task like the load,
    /// because the iCloud store coordinates the file removal. Errors are swallowed: a failed delete
    /// simply leaves the note in place, and the reload re-reflects the true on-disk state.
    func delete(id: UUID) async {
        await Task.detached(priority: .userInitiated) { [store] in
            try? store.delete(id: id)
        }.value
        await reload()
    }

    /// Reload the list. `loadAll()` runs on a detached task (it can block on iCloud coordination);
    /// only the assignment touches this main-actor state, then `onStateChange` fires.
    func reload() async {
        let loaded = await Task.detached(priority: .userInitiated) { [store] in
            store.loadAll()
        }.value
        notes = loaded
        didLoad = true
        onStateChange?()
    }
}
