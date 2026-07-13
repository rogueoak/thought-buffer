import SwiftUI

/// The notes feed: a scrollable list of real saved notes on the River Mist palette, with a
/// toolbar (mic + gear) and a prominent record button that presents dictation. Notes load from
/// the `NoteStore` and refresh after a dictation session saves.
struct StreamListView: View {
    /// The note store, injected from the composition root (`AppDependencies`) rather than
    /// allocated inline, so one place wires the concrete store. Kept for the dictation session.
    private let store: NoteStoring
    /// Builds the text processor for a dictation session (Mira control words by default). Injected
    /// from the composition root so one place decides the processor.
    private let makeTextProcessor: () -> TextProcessor
    /// The user settings store, threaded to the Settings screen. Injected from the composition root
    /// so Settings edits the same instance the processor factory reads.
    private let settingsStore: SettingsStoring
    /// Where notes are stored (iCloud vs local). Shown read-only in Settings.
    private let noteStoreKind: NoteStoreKind
    /// The ONE shared playback controller from the composition root, handed to each detail view so
    /// the phone and CarPlay drive the same media center. Nil in bare/preview call sites, where the
    /// detail view falls back to a private controller over the store resolver.
    private let playbackController: NotePlaybackController?
    /// The feed model: owns the notes state, the off-main load, and the iCloud observer wiring.
    @StateObject private var feed: StreamFeed
    /// The shared pending-session route. Observed so a hands-free start (Siri, CarPlay) requested
    /// while the app was backgrounded opens dictation the moment the app comes forward, and so the
    /// Record button starts a session through the same seam every other entry point uses.
    @ObservedObject private var sessionRoute: PendingSessionRoute
    @State private var showSettings = false
    /// Navigation stack path. Pushing a `Note` opens its detail page; used to land the user on the
    /// note they just recorded when a session ends (feedback 0007).
    @State private var path: [Note] = []

    /// Presentation of the dictation screen is a pure function of the pending route: it is shown
    /// exactly while a start is pending (`PendingSessionRoute.shouldPresent`). Setting it false - the
    /// header chevron, a finished save, a swipe-down - consumes the pending start. Deriving the
    /// binding from the route (rather than a separate `@State` bool synced by `onChange`) means a
    /// start requested while backgrounded opens on appear, and a re-request right after a session
    /// ends re-opens, with no lost-edge cases.
    private var showDictation: Binding<Bool> {
        Binding(
            get: { PendingSessionRoute.shouldPresent(startRequested: sessionRoute.startRequested) },
            set: { present in if !present { sessionRoute.consume() } }
        )
    }

    init(
        store: NoteStoring,
        makeTextProcessor: @escaping () -> TextProcessor,
        settingsStore: SettingsStoring,
        noteStoreKind: NoteStoreKind = .local,
        noteObserver: UbiquitousNoteObserving? = nil,
        sessionRoute: PendingSessionRoute,
        playbackController: NotePlaybackController? = nil
    ) {
        self.store = store
        self.makeTextProcessor = makeTextProcessor
        self.settingsStore = settingsStore
        self.noteStoreKind = noteStoreKind
        self.playbackController = playbackController
        self.sessionRoute = sessionRoute
        _feed = StateObject(wrappedValue: StreamFeed(store: store, observer: noteObserver))
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if feed.notes.isEmpty && feed.didLoad {
                    // Center in the frame that REMAINS after the record button's safe-area inset, so
                    // the help text can never sit under the button (feedback 0005).
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // A `List` (not a ScrollView + LazyVStack) so iOS-standard swipe-to-delete works
                    // (feedback 0005). River Mist styling is kept by hiding the list chrome: the app
                    // background shows through (clear row/list backgrounds), separators are hidden,
                    // and each row keeps the NoteCard's own surface/border via inset row spacing.
                    List {
                        ForEach(feed.notes) { note in
                            NavigationLink(value: note) {
                                NoteCard(note: note)
                            }
                            .listRowInsets(EdgeInsets(
                                top: CanopySpacing.x1_5,
                                leading: CanopySpacing.x4,
                                bottom: CanopySpacing.x1_5,
                                trailing: CanopySpacing.x4
                            ))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await feed.delete(id: note.id) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .padding(.top, CanopySpacing.x2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CanopyColor.bg.ignoresSafeArea())
            // Pin the record button in the bottom safe-area inset rather than overlaying content:
            // SwiftUI then reserves its height under BOTH the empty state and the scrolling list, so
            // the button can never overlap the empty-state help text or the last note (feedback 0005).
            .safeAreaInset(edge: .bottom) {
                RecordButton { sessionRoute.startNewSession() }
                    .padding(.bottom, CanopySpacing.x6)
            }
            // Surface a failed delete as a brief, non-blocking banner (feedback 0005): a coordinated
            // delete can throw (iCloud), which used to be swallowed silently, leaving the note on
            // screen with no explanation. The note stays visible (the reload re-reflects disk); this
            // just tells the user the removal did not take. Auto-dismisses after a moment.
            .overlay(alignment: .top) {
                if feed.deleteFailed {
                    DeleteFailedBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task {
                            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                            feed.clearDeleteFailure()
                        }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: feed.deleteFailed)
            .navigationTitle("Stream")
            .navigationDestination(for: Note.self) { note in
                // Pass the store as a lazy resolver rather than resolving here: the detail view's
                // playback model validates the recording off the main actor at play time, so pushing
                // into a note never blocks on the coordinated presence check (iCloud navigation jank).
                NoteDetailView(
                    note: note,
                    resolver: StoreAudioURLResolver(store: store),
                    controller: playbackController
                )
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        sessionRoute.startNewSession()
                    } label: {
                        Image(systemName: "mic.fill")
                    }
                    .tint(CanopyColor.primary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .tint(CanopyColor.primary)
                }
            }
            .fullScreenCover(isPresented: showDictation) {
                DictationView(
                    model: DictationViewModel(
                        store: store,
                        processor: makeTextProcessor(),
                        // Record audio for this session unless the user chose transcript-only. Read
                        // now (per session) so a Settings change applies to the next session started.
                        recordsAudio: settingsStore.audioRetention.recordsAudio
                    )
                ) { savedNote in
                    // The session is over: consuming the pending route (via the binding's setter on
                    // dismiss) closes the cover. Refresh the feed and open the saved note's page, so the
                    // user lands on what they just recorded rather than back on the list (feedback 0007).
                    if let savedNote {
                        Task { await feed.reload() }
                        path = [savedNote]
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(settings: settingsStore, storeKind: noteStoreKind)
            }
        }
        .tint(CanopyColor.primary)
        // A `.task` (not onAppear/onDisappear) so the feed wires its observer once for the lifetime
        // of this view in the stream, and is not stopped/restarted every time we push into a note
        // detail on the same stack. `withTaskCancellationHandler` tears the observer down the moment
        // the task is cancelled (the view left the hierarchy), with no polling delay.
        .task {
            await withTaskCancellationHandler {
                await feed.start()
                // Park until cancelled; the handler below runs `stop()` immediately on cancel.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                }
            } onCancel: {
                Task { @MainActor in feed.stop() }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: CanopySpacing.x3) {
            Image(systemName: "waveform")
                .font(.system(size: CanopyFont.sizeX4xl, weight: .semibold))
                .foregroundStyle(CanopyColor.primary)
            Text("No notes yet")
                .font(.system(size: CanopyFont.sizeXl, weight: .semibold))
                .foregroundStyle(CanopyColor.text)
            Text("Tap Record and start talking. Your words land here as a note.")
                .font(.system(size: CanopyFont.sizeSm))
                .foregroundStyle(CanopyColor.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CanopySpacing.x8)
        }
    }
}

/// A brief, non-blocking banner shown when a note delete fails, styled with Canopy danger tokens.
private struct DeleteFailedBanner: View {
    var body: some View {
        HStack(spacing: CanopySpacing.x2) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Could not delete note")
                .font(.system(size: CanopyFont.sizeSm, weight: .semibold))
        }
        .foregroundStyle(CanopyColor.dangerForeground)
        .padding(.horizontal, CanopySpacing.x4)
        .padding(.vertical, CanopySpacing.x2)
        .background(CanopyColor.danger)
        .clipShape(Capsule())
        .shadow(color: CanopyColor.overlay.opacity(0.2), radius: 8, y: 4)
        .padding(.top, CanopySpacing.x2)
    }
}

/// The floating record button that opens the dictation screen.
private struct RecordButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: CanopySpacing.x2) {
                Image(systemName: "mic.fill")
                Text("Record")
                    .font(.system(size: CanopyFont.sizeBase, weight: .semibold))
            }
            .foregroundStyle(CanopyColor.primaryForeground)
            .padding(.horizontal, CanopySpacing.x6)
            .padding(.vertical, CanopySpacing.x3)
            .background(CanopyColor.primary)
            .clipShape(Capsule())
            .shadow(color: CanopyColor.overlay.opacity(0.25), radius: 12, y: 6)
        }
    }
}

#Preview {
    StreamListView(
        store: NoteStore(),
        makeTextProcessor: { MiraTextProcessor() },
        settingsStore: UserDefaultsSettingsStore(),
        sessionRoute: PendingSessionRoute()
    )
}
