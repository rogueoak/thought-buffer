import Foundation

/// Which storage backend the app resolved to. Observable so a later Settings status can show
/// "syncing via iCloud" vs "on this device" without re-deriving the choice.
enum ThoughtStoreKind: Equatable {
    /// Thoughts live in the iCloud Drive ubiquity container and sync across devices.
    case iCloud
    /// Thoughts live in the app's local `Documents/ThoughtStream/`. iCloud was unavailable.
    case local
}

/// The resolved storage selection: the store the app should use, which kind it is, and, for
/// iCloud, an observer that refreshes the Stream list on sync/external edits (nil for local).
struct ThoughtStoreSelection {
    let store: ThoughtStoring
    let kind: ThoughtStoreKind
    /// A live-update observer for iCloud; nil for local storage (nothing external to watch).
    let observer: UbiquitousThoughtObserving?
}

/// Picks the thought store at startup: `ICloudThoughtStore` when the ubiquity container resolves, else
/// the local `ThoughtStore`. This is the one place that decides, so the rest of the app depends only
/// on `ThoughtStoring` and never re-runs availability logic. The choice is returned (not hidden) so
/// the composition root can hold `kind` for a future Settings status.
///
/// Fallback is safe: resolving the container off the main actor, and if it is nil - not signed in,
/// no provisioning, or the Simulator with no account - the app uses local storage and behaves
/// exactly as before. The local store is never touched, so switching backends never loses thoughts.
struct ThoughtStoreFactory {
    let containerProvider: UbiquityContainerProviding
    /// Builds the iCloud observer once iCloud is selected. Injectable so tests can stub it.
    let makeObserver: () -> UbiquitousThoughtObserving

    init(
        containerProvider: UbiquityContainerProviding = FileManagerUbiquityContainerProvider(),
        makeObserver: @escaping () -> UbiquitousThoughtObserving = { MetadataUbiquitousThoughtObserver() }
    ) {
        self.containerProvider = containerProvider
        self.makeObserver = makeObserver
    }

    /// Resolve the store. Runs the container lookup off the main actor (it can block) and returns
    /// iCloud when it resolves, otherwise local. Never throws: unavailable iCloud is a normal
    /// path, not an error.
    func make() async -> ThoughtStoreSelection {
        if let containerURL = await containerProvider.containerURL() {
            let documents = containerURL.appendingPathComponent("Documents", isDirectory: true)
            let store = ICloudThoughtStore(containerDocumentsURL: documents)
            return ThoughtStoreSelection(store: store, kind: .iCloud, observer: makeObserver())
        }
        return ThoughtStoreSelection(store: ThoughtStore(), kind: .local, observer: nil)
    }
}
