import Foundation

/// Which storage backend the app resolved to. Observable so a later Settings status can show
/// "syncing via iCloud" vs "on this device" without re-deriving the choice.
enum NoteStoreKind: Equatable {
    /// Notes live in the iCloud Drive ubiquity container and sync across devices.
    case iCloud
    /// Notes live in the app's local `Documents/ThoughtStream/`. iCloud was unavailable.
    case local
}

/// The resolved storage selection: the store the app should use, which kind it is, and, for
/// iCloud, an observer that refreshes the Stream list on sync/external edits (nil for local).
struct NoteStoreSelection {
    let store: NoteStoring
    let kind: NoteStoreKind
    /// A live-update observer for iCloud; nil for local storage (nothing external to watch).
    let observer: UbiquitousNoteObserving?
}

/// Picks the note store at startup: `ICloudNoteStore` when the ubiquity container resolves, else
/// the local `NoteStore`. This is the one place that decides, so the rest of the app depends only
/// on `NoteStoring` and never re-runs availability logic. The choice is returned (not hidden) so
/// the composition root can hold `kind` for a future Settings status.
///
/// Fallback is safe: resolving the container off the main actor, and if it is nil - not signed in,
/// no provisioning, or the Simulator with no account - the app uses local storage and behaves
/// exactly as before. The local store is never touched, so switching backends never loses notes.
struct NoteStoreFactory {
    let containerProvider: UbiquityContainerProviding
    /// Builds the iCloud observer once iCloud is selected. Injectable so tests can stub it.
    let makeObserver: () -> UbiquitousNoteObserving

    init(
        containerProvider: UbiquityContainerProviding = FileManagerUbiquityContainerProvider(),
        makeObserver: @escaping () -> UbiquitousNoteObserving = { MetadataUbiquitousNoteObserver() }
    ) {
        self.containerProvider = containerProvider
        self.makeObserver = makeObserver
    }

    /// Resolve the store. Runs the container lookup off the main actor (it can block) and returns
    /// iCloud when it resolves, otherwise local. Never throws: unavailable iCloud is a normal
    /// path, not an error.
    func make() async -> NoteStoreSelection {
        if let containerURL = await containerProvider.containerURL() {
            let documents = containerURL.appendingPathComponent("Documents", isDirectory: true)
            let store = ICloudNoteStore(containerDocumentsURL: documents)
            return NoteStoreSelection(store: store, kind: .iCloud, observer: makeObserver())
        }
        return NoteStoreSelection(store: NoteStore(), kind: .local, observer: nil)
    }
}
