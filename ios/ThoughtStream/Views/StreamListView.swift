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
    /// The feed model: owns the notes state, the off-main load, and the iCloud observer wiring.
    @StateObject private var feed: StreamFeed
    /// The shared pending-session route. Observed so a hands-free start (Siri, CarPlay) requested
    /// while the app was backgrounded opens dictation the moment the app comes forward, and so the
    /// Record button starts a session through the same seam every other entry point uses.
    @ObservedObject private var sessionRoute: PendingSessionRoute
    @State private var showSettings = false

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
        noteObserver: UbiquitousNoteObserving? = nil,
        sessionRoute: PendingSessionRoute
    ) {
        self.store = store
        self.makeTextProcessor = makeTextProcessor
        self.sessionRoute = sessionRoute
        _feed = StateObject(wrappedValue: StreamFeed(store: store, observer: noteObserver))
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                CanopyColor.bg.ignoresSafeArea()

                if feed.notes.isEmpty && feed.didLoad {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: CanopySpacing.x3) {
                            ForEach(feed.notes) { note in
                                NavigationLink(value: note) {
                                    NoteCard(note: note)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, CanopySpacing.x4)
                        .padding(.top, CanopySpacing.x3)
                        // Leave room for the floating record button.
                        .padding(.bottom, CanopySpacing.x24)
                    }
                }

                RecordButton { sessionRoute.startNewSession() }
                    .padding(.bottom, CanopySpacing.x6)
            }
            .navigationTitle("Stream")
            .navigationDestination(for: Note.self) { note in
                NoteDetailView(note: note)
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
                    model: DictationViewModel(store: store, processor: makeTextProcessor())
                ) { savedNote in
                    // The session is over: consuming the pending route (via the binding's setter on
                    // dismiss) closes the cover; here just refresh the feed if a note was saved.
                    if savedNote != nil {
                        Task { await feed.reload() }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
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
        sessionRoute: PendingSessionRoute()
    )
}
