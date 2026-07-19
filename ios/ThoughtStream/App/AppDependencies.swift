import Foundation

/// The app's composition root: the single place that wires up concrete implementations of the
/// app's seams (thought storage today; more later). Created once in `ThoughtStreamApp` and passed
/// down, so no view or view model allocates its own concrete store.
struct AppDependencies {
    /// The thought persistence backend used across the app.
    let thoughtStore: ThoughtStoring

    /// Which backend was selected (iCloud vs local). Observable so a later Settings status can
    /// show where thoughts live without re-running the availability check.
    let thoughtStoreKind: ThoughtStoreKind

    /// Watches the iCloud thoughts folder for external edits / synced-in files so the Stream list
    /// refreshes. Nil when storage is local (nothing external to watch).
    let thoughtObserver: UbiquitousThoughtObserving?

    /// The user's configurable settings: control phrase and spelling overrides. Held so the
    /// Settings screen edits the same instance the processor factory reads. Local (`UserDefaults`)
    /// only; see spec 0006.
    let settingsStore: SettingsStoring

    /// Builds the text processor for a dictation session. Returns a fresh one each time so a
    /// stateful processor never leaks across sessions, and reads CURRENT settings at build time so
    /// edits in Settings apply to the next session started. Defaults to a `CompositeTextProcessor`
    /// composing the Mira control-word processor (with the configured control phrase) and the
    /// spelling-override processor.
    let makeTextProcessor: () -> TextProcessor

    /// The shared "start a new dictation session" seam. The Record button, the Siri App Intent, and
    /// the CarPlay action all request a start through this one route, so every entry point begins a
    /// session identically. The root view observes it and opens `DictationView`.
    let sessionRoute: PendingSessionRoute

    /// The ONE headless playback controller for a saved thought's recording (spec 0008). Both the phone
    /// detail view (through `ThoughtPlaybackModel`) and the CarPlay scene drive and observe THIS shared
    /// instance, so there is exactly one writer of `MPNowPlayingInfoCenter` and one owner of the
    /// remote transport commands. Hoisted here (rather than per-surface) so that once the CarPlay
    /// entitlement ships, the two surfaces cannot race on the media center or clobber each other's
    /// transport observation - the observation is multi-observer safe on the controller itself.
    /// `@MainActor` because the controller is main-actor.
    let playbackController: ThoughtPlaybackController

    /// The phone side of the Apple Watch link (spec 0023), or nil when no watch support is wired (tests,
    /// screenshot tooling). Receives watch captures (ingesting each into a thought via file transcription)
    /// and pushes the recent-thoughts projection back to the watch. Activated at launch in `resolve`.
    let watchCoordinator: PhoneConnectivityCoordinator?

    /// `@MainActor` because the session route is a main-actor `ObservableObject`; the composition
    /// root is built on the main actor at launch (see `resolve`), so this is not a constraint in
    /// practice.
    @MainActor
    init(
        thoughtStore: ThoughtStoring = ThoughtStore(),
        thoughtStoreKind: ThoughtStoreKind = .local,
        thoughtObserver: UbiquitousThoughtObserving? = nil,
        settingsStore: SettingsStoring = UserDefaultsSettingsStore(),
        makeTextProcessor: (() -> TextProcessor)? = nil,
        sessionRoute: PendingSessionRoute? = nil,
        playbackController: ThoughtPlaybackController? = nil,
        watchCoordinator: PhoneConnectivityCoordinator? = nil
    ) {
        self.watchCoordinator = watchCoordinator
        self.thoughtStore = thoughtStore
        self.thoughtStoreKind = thoughtStoreKind
        self.thoughtObserver = thoughtObserver
        self.settingsStore = settingsStore
        // Default factory reads current settings each call and builds a fresh composite, so an edit
        // in Settings applies to the next session. Injectable for tests that want a fixed processor.
        self.makeTextProcessor = makeTextProcessor ?? {
            CompositeTextProcessor(
                // Spec 0018: build from the FULL trigger set - the primary control word plus its
                // validated aliases (common mishearings) - assembled through the shared `ControlPhrase`
                // seam so the primary word always leads and no alias can shadow it. Read at build time,
                // so an aliases edit takes effect on the next session, like the control phrase.
                triggerWords: ControlPhrase.triggerWords(
                    primaryWord: settingsStore.controlPhrase,
                    aliases: settingsStore.controlPhraseAliases
                ),
                overrides: settingsStore.spellingOverrides,
                // Spec 0016: the filler-removal stage is present only when refine is on, read at build
                // time so a Settings toggle takes effect on the next session (like the control phrase).
                removesFillers: settingsStore.refineTranscript
            )
        }
        // Built here (on the main actor) when none is injected, so the route's main-actor
        // initializer is never called from a nonisolated default-argument context.
        self.sessionRoute = sessionRoute ?? PendingSessionRoute()
        // The single shared controller, resolving recordings through the same store and reading the
        // current lock-screen-title preference at publish time (a Settings toggle applies next
        // update). Built here on the main actor for the same reason as the route.
        self.playbackController = playbackController ?? ThoughtPlaybackController(
            resolver: StoreAudioURLResolver(store: thoughtStore),
            lockScreenTitle: { settingsStore.lockScreenTitle }
        )
    }

    /// The live dependencies, published once the app resolves them at launch. App Intents and the
    /// CarPlay scene are instantiated by the system OUTSIDE the SwiftUI tree, so they cannot receive
    /// the session route by injection; they reach the live route through here. This is a narrow,
    /// documented bridge for exactly that case, not general service location - everything inside the
    /// view tree is still injected. `@MainActor` isolates the mutable shared state.
    @MainActor private(set) static var shared: AppDependencies?

    /// Clear the resolved root back to the unresolved (nil) state. Test-only support so a test can
    /// exercise the pre-resolution `sessionStarter` path deterministically, regardless of whether an
    /// earlier test resolved the root; production only ever transitions nil -> resolved via `resolve`.
    @MainActor static func resetSharedForTesting() {
        shared = nil
    }

    /// The shared session starter for hands-free callers (Siri App Intent, CarPlay). Returns the
    /// live route once the app has resolved; before that (a COLD hands-free launch, where the intent
    /// runs before `resolve()` finishes) it returns a latch-setting starter so the request is not
    /// dropped - the route seeds itself from the latch the moment it is created. Never nil, so a
    /// cold-launch start always lands. Allocates a fresh `ColdStartSessionStarter` on each
    /// pre-resolution call; negligible, and it happens only on the rare cold hands-free launch.
    @MainActor
    static var sessionStarter: SessionStarter { shared?.sessionRoute ?? ColdStartSessionStarter() }

    /// Resolve dependencies at startup, picking iCloud storage when the ubiquity container is
    /// available and falling back to local otherwise. Runs the container lookup off the main actor
    /// (it can block), so this is async and the app awaits it before rooting the first screen.
    /// Publishes the result to `shared` so hands-free entry points can reach the session route.
    @MainActor
    static func resolve(
        factory: ThoughtStoreFactory = ThoughtStoreFactory(),
        settingsStore: SettingsStoring = UserDefaultsSettingsStore()
    ) async -> AppDependencies {
        let selection = await factory.make()
        // Sweep expired recordings once at launch, off the main actor (the store read/delete can
        // block on coordinated iCloud IO). A no-op unless retention is auto-delete. The text of a
        // swept thought is untouched; only its recording goes.
        let retention = settingsStore.audioRetention
        if retention.autoDeleteDays != nil {
            let sweeper = AudioRetentionSweeper(store: selection.store)
            _ = await Task.detached { await sweeper.sweep(retention: retention) }.value
        }
        // The Apple Watch link (spec 0023): receive watch captures (ingest each into a thought) and push
        // the recent-thoughts projection back. The providers capture the store (Sendable) and project /
        // resolve on demand, so the coordinator never reaches into a view model. Activated below.
        let store = selection.store
        let watchCoordinator = PhoneConnectivityCoordinator(
            ingestService: WatchCaptureIngestService(store: store),
            recentThoughtsProvider: { RecentThoughtsProjector.project(store.loadAll()) },
            audioURLProvider: { id in store.audioURL(for: id) }
        )
        // No `makeTextProcessor` passed: the init's default factory builds a `CompositeTextProcessor`
        // from `settingsStore` each session, so control-phrase and override edits take effect next
        // session.
        let dependencies = AppDependencies(
            thoughtStore: selection.store,
            thoughtStoreKind: selection.kind,
            thoughtObserver: selection.observer,
            settingsStore: settingsStore,
            watchCoordinator: watchCoordinator
        )
        // Activate the session so a watch capture can arrive and the first projection is pushed. A no-op
        // where WatchConnectivity is unavailable (an iPad), so the iOS build stays unaffected.
        watchCoordinator.start()
        shared = dependencies
        return dependencies
    }
}
