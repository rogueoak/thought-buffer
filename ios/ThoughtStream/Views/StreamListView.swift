import SwiftUI

/// The notes feed: a scrollable list of mock note cards on the River Mist palette,
/// with a toolbar (mic + gear) and a prominent record button that presents dictation.
struct StreamListView: View {
    private let notes = MockNotes.all
    @State private var showDictation = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                CanopyColor.bg.ignoresSafeArea()

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
            .sheet(isPresented: $showDictation) {
                DictationView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
        .tint(CanopyColor.primary)
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
    StreamListView()
}
