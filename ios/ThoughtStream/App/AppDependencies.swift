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

    /// The shared "start a new dictation session" seam. The Record button, the Siri App Intent, and
    /// the CarPlay action all request a start through this one route, so every entry point begins a
    /// session identically. The root view observes it and opens `DictationView`.
    let sessionRoute: PendingSessionRoute

    /// `@MainActor` because the session route is a main-actor `ObservableObject`; the composition
    /// root is built on the main actor at launch (see `resolve`), so this is not a constraint in
    /// practice.
    @MainActor
    init(
        noteStore: NoteStoring = NoteStore(),
        noteStoreKind: NoteStoreKind = .local,
        noteObserver: UbiquitousNoteObserving? = nil,
        makeTextProcessor: @escaping () -> TextProcessor = { MiraTextProcessor() },
        sessionRoute: PendingSessionRoute? = nil
    ) {
        self.noteStore = noteStore
        self.noteStoreKind = noteStoreKind
        self.noteObserver = noteObserver
        self.makeTextProcessor = makeTextProcessor
        // Built here (on the main actor) when none is injected, so the route's main-actor
        // initializer is never called from a nonisolated default-argument context.
        self.sessionRoute = sessionRoute ?? PendingSessionRoute()
    }

    /// The live dependencies, published once the app resolves them at launch. App Intents and the
    /// CarPlay scene are instantiated by the system OUTSIDE the SwiftUI tree, so they cannot receive
    /// the session route by injection; they reach the live route through here. This is a narrow,
    /// documented bridge for exactly that case, not general service location - everything inside the
    /// view tree is still injected. `@MainActor` isolates the mutable shared state.
    @MainActor private(set) static var shared: AppDependencies?

    /// The shared session starter for hands-free callers (Siri App Intent, CarPlay). Returns the
    /// live route once the app has resolved; before that (a COLD hands-free launch, where the intent
    /// runs before `resolve()` finishes) it returns a latch-setting starter so the request is not
    /// dropped - the route seeds itself from the latch the moment it is created. Never nil, so a
    /// cold-launch start always lands.
    @MainActor
    static var sessionStarter: SessionStarter { shared?.sessionRoute ?? ColdStartSessionStarter() }

    /// Resolve dependencies at startup, picking iCloud storage when the ubiquity container is
    /// available and falling back to local otherwise. Runs the container lookup off the main actor
    /// (it can block), so this is async and the app awaits it before rooting the first screen.
    /// Publishes the result to `shared` so hands-free entry points can reach the session route.
    @MainActor
    static func resolve(
        factory: NoteStoreFactory = NoteStoreFactory(),
        makeTextProcessor: @escaping () -> TextProcessor = { MiraTextProcessor() }
    ) async -> AppDependencies {
        let selection = await factory.make()
        let dependencies = AppDependencies(
            noteStore: selection.store,
            noteStoreKind: selection.kind,
            noteObserver: selection.observer,
            makeTextProcessor: makeTextProcessor
        )
        shared = dependencies
        return dependencies
    }
}
