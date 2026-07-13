import Foundation

/// Owns the Stream list's data and its live-update wiring, so the view stays presentational and
/// the load/observe behavior is unit-testable without SwiftUI.
///
/// Loads notes through the injected `NoteStoring` off the main thread (the iCloud store's
/// `loadAll()` is a chain of coordinated reads that can block on the sync daemon), and, when an
/// iCloud observer is present, refreshes the list on external edits / synced-in files. On local
/// storage there is no observer and this just loads.
@MainActor
final class StreamFeed: ObservableObject {
    /// The notes to render, newest first. Empty until the first load completes.
    @Published private(set) var notes: [Note] = []
    /// True once an initial load has finished, so the view can tell "empty" from "not loaded yet".
    @Published private(set) var didLoad = false

    private let store: NoteStoring
    private let observer: UbiquitousNoteObserving?
    private var started = false

    init(store: NoteStoring, observer: UbiquitousNoteObserving? = nil) {
        self.store = store
        self.observer = observer
    }

    /// Do the initial load, then wire the iCloud observer (if any) to reload on change. Idempotent:
    /// starting twice does not double-wire the observer. Call from the view's `.task`.
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
    /// a stale reference back into a gone feed. Call from the view's task cancellation.
    func stop() {
        guard started else { return }
        started = false
        observer?.onChange = nil
        observer?.stop()
    }

    /// Reload the list. `loadAll()` runs on a detached task (it can block on iCloud coordination);
    /// only the assignment touches this main-actor state.
    func reload() async {
        let loaded = await Task.detached(priority: .userInitiated) { [store] in
            store.loadAll()
        }.value
        notes = loaded
        didLoad = true
    }
}
