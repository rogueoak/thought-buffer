import SwiftUI

/// The notes feed: a scrollable list of real saved notes on the River Mist palette, with a
/// toolbar (mic + gear) and a prominent record button that presents dictation. Notes load from
/// the `NoteStore` and refresh after a dictation session saves.
struct StreamListView: View {
    /// The note store, injected from the composition root (`AppDependencies`) rather than
    /// allocated inline, so one place wires the concrete store.
    private let store: NoteStoring
    /// Builds the text processor for a dictation session (Mira control words by default). Injected
    /// from the composition root so one place decides the processor.
    private let makeTextProcessor: () -> TextProcessor
    @State private var notes: [Note] = []
    @State private var didLoad = false
    @State private var showDictation = false
    @State private var showSettings = false

    init(
        store: NoteStoring,
        makeTextProcessor: @escaping () -> TextProcessor = { MiraTextProcessor() }
    ) {
        self.store = store
        self.makeTextProcessor = makeTextProcessor
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                CanopyColor.bg.ignoresSafeArea()

                if notes.isEmpty && didLoad {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: CanopySpacing.x3) {
                            ForEach(notes) { note in
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

                RecordButton { showDictation = true }
                    .padding(.bottom, CanopySpacing.x6)
            }
            .navigationTitle("Stream")
            .navigationDestination(for: Note.self) { note in
                NoteDetailView(note: note)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showDictation = true
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
            .fullScreenCover(isPresented: $showDictation) {
                DictationView(
                    model: DictationViewModel(store: store, processor: makeTextProcessor())
                ) { savedNote in
                    if savedNote != nil {
                        reload()
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
        .tint(CanopyColor.primary)
        .onAppear(perform: loadIfNeeded)
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

    private func loadIfNeeded() {
        guard !didLoad else { return }
        reload()
    }

    private func reload() {
        notes = store.loadAll()
        didLoad = true
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
    StreamListView(store: NoteStore())
}
