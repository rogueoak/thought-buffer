import Foundation

/// The app's composition root: the single place that wires up concrete implementations of the
/// app's seams (note storage today; more later). Created once in `ThoughtStreamApp` and passed
/// down, so no view or view model allocates its own concrete store.
struct AppDependencies {
    /// The note persistence backend used across the app.
    let noteStore: NoteStoring

    /// Which backend was selected (iCloud vs local). Observable so a later Settings status can
    /// show where notes live without re-running the availability check.
    let noteStoreKind: NoteStoreKind

    /// Watches the iCloud notes folder for external edits / synced-in files so the Stream list
    /// refreshes. Nil when storage is local (nothing external to watch).
    let noteObserver: UbiquitousNoteObserving?

    /// Builds the text processor for a dictation session. Returns a fresh one each time so a
    /// stateful processor never leaks across sessions. Defaults to the Mira control-word
    /// processor with the built-in control word.
    let makeTextProcessor: () -> TextProcessor

    init(
        noteStore: NoteStoring = NoteStore(),
        noteStoreKind: NoteStoreKind = .local,
        noteObserver: UbiquitousNoteObserving? = nil,
        makeTextProcessor: @escaping () -> TextProcessor = { MiraTextProcessor() }
    ) {
        self.noteStore = noteStore
        self.noteStoreKind = noteStoreKind
        self.noteObserver = noteObserver
        self.makeTextProcessor = makeTextProcessor
    }

    /// Resolve dependencies at startup, picking iCloud storage when the ubiquity container is
    /// available and falling back to local otherwise. Runs the container lookup off the main actor
    /// (it can block), so this is async and the app awaits it before rooting the first screen.
    static func resolve(
        factory: NoteStoreFactory = NoteStoreFactory(),
        makeTextProcessor: @escaping () -> TextProcessor = { MiraTextProcessor() }
    ) async -> AppDependencies {
        let selection = await factory.make()
        return AppDependencies(
            noteStore: selection.store,
            noteStoreKind: selection.kind,
            noteObserver: selection.observer,
            makeTextProcessor: makeTextProcessor
        )
    }
}
