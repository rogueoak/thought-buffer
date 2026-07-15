import SwiftUI

/// Detail for a single note: its paragraphs and timestamp, themed. When the note carries a recording
/// (spec 0007), a simple Play / Stop control plays it back in full. The text is editable with the
/// keyboard, and a Resume action reopens the note into a recording session to keep dictating
/// (feedback 0008).
struct NoteDetailView: View {
    let note: Note
    @StateObject private var playback: NotePlaybackModel

    /// Called with the current note when the user taps Resume, so the composition root can reopen a
    /// recording session seeded with it. Nil at bare/preview call sites (no Resume affordance shown).
    private let onResume: ((Note) -> Void)?
    /// Called with the edited note when the user commits a keyboard edit, so the composition root can
    /// persist it and refresh the feed. Nil at bare/preview call sites (editing then shows no Save).
    private let onCommitEdit: ((Note) -> Void)?

    /// The note's paragraphs as shown/edited. Seeded from the note; edits mutate this and, on commit,
    /// build an updated note handed back through `onCommitEdit`.
    @State private var paragraphs: [String]
    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var editorFocused: Bool

    /// Build the detail view. Prefers the ONE shared `NotePlaybackController` (so the phone and
    /// CarPlay drive the same media center and never race); when none is supplied - a preview, a
    /// screenshot build, or a bare call site - it falls back to a private controller over the given
    /// `resolver`, which resolves the recording lazily (off the main actor, at play time) so
    /// navigation never blocks on the coordinated presence check. When the note claims no audio, no
    /// play affordance shows.
    init(
        note: Note,
        resolver: AudioURLResolving,
        player: AudioNotePlayer? = nil,
        controller: NotePlaybackController? = nil,
        onResume: ((Note) -> Void)? = nil,
        onCommitEdit: ((Note) -> Void)? = nil
    ) {
        self.note = note
        self.onResume = onResume
        self.onCommitEdit = onCommitEdit
        _paragraphs = State(initialValue: note.paragraphs)
        // The full note is passed through so the shared playback controller titles the system Now
        // Playing item (lock screen / Control Center) and reads the recording duration.
        let controller = controller ?? NotePlaybackController(resolver: resolver, player: player)
        _playback = StateObject(wrappedValue: NotePlaybackModel(note: note, controller: controller))
    }

    var body: some View {
        ZStack {
            CanopyColor.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: CanopySpacing.x4) {
                    HStack(spacing: CanopySpacing.x2) {
                        Image(systemName: "clock")
                        Text(RelativeTime.label(for: note.createdAt))
                        Text("-")
                        // Recording duration for a recorded note, else word count (feedback 0010).
                        Text(currentNote.metaStatLabel)
                    }
                    .font(.system(size: CanopyFont.sizeXs))
                    .foregroundStyle(CanopyColor.textSubtle)

                    if playback.canPlay {
                        playButton
                    }

                    if isEditing {
                        TextEditor(text: $draft)
                            .focused($editorFocused)
                            .font(.system(size: CanopyFont.sizeBase))
                            .foregroundStyle(CanopyColor.text)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 240)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // Tap the text to edit (feedback 0010): the note body IS the edit affordance,
                        // so the separate Edit button is gone. Only tappable where the call site can
                        // persist the result (`onCommitEdit` supplied); a bare/preview note stays read
                        // only. `contentShape` makes the whole column - gaps included - the tap target.
                        VStack(alignment: .leading, spacing: CanopySpacing.x4) {
                            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                                Text(paragraph)
                                    .font(.system(size: CanopyFont.sizeBase))
                                    .foregroundStyle(CanopyColor.text)
                                    .lineSpacing(4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { if onCommitEdit != nil { beginEdit() } }
                        .accessibilityAddTraits(onCommitEdit != nil ? .isButton : [])
                        .accessibilityHint(onCommitEdit != nil ? "Double tap to edit" : "")
                    }
                }
                .padding(CanopySpacing.x5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CanopyColor.surface)
                .clipShape(RoundedRectangle(cornerRadius: CanopyRadius.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CanopyRadius.lg, style: .continuous)
                        .stroke(CanopyColor.border, lineWidth: 1)
                )
                .padding(CanopySpacing.x4)
            }
        }
        // Resume sits centered at the bottom of the screen (feedback 0008), clear of the scrolling
        // note body. Hidden while editing text, and only when a call site can reopen a session.
        .safeAreaInset(edge: .bottom) {
            if let onResume, !isEditing {
                resumeButton { onResume(currentNote) }
                    .padding(.bottom, CanopySpacing.x4)
            }
        }
        .navigationTitle(currentNote.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Editing starts by tapping the note text (feedback 0010), so there is no read-mode Edit
            // button; the toolbar shows only a Done button WHILE editing to commit. Gated on the call
            // site being able to persist the result (`onCommitEdit` supplied).
            if onCommitEdit != nil, isEditing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { commitEdit() }
                        .tint(CanopyColor.primary)
                }
            }
        }
        // Stop playback if the user navigates away mid-play, so audio never keeps running off-screen.
        .onDisappear { playback.stop() }
    }

    /// The note as it currently stands (edits applied), with the title re-derived from the first line
    /// and the original recording/timings preserved. Handed to `onCommitEdit` and `onResume`.
    private var currentNote: Note {
        Note(
            id: note.id,
            title: Note.deriveTitle(paragraphs: paragraphs, createdAt: note.createdAt),
            paragraphs: paragraphs,
            createdAt: note.createdAt,
            audioFileName: note.audioFileName,
            // An edit can shrink the paragraph count; cap timings so the note never carries more
            // timings than paragraphs (parity with the record-screen edit; engineer review).
            timings: Array(note.timings.prefix(paragraphs.count))
        )
    }

    /// The Resume control (reopen the note into a recording session), styled as a prominent pill for
    /// the bottom bar.
    private func resumeButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: CanopySpacing.x2) {
                Image(systemName: "mic.fill")
                Text("Resume")
                    .font(.system(size: CanopyFont.sizeBase, weight: .semibold))
            }
            .foregroundStyle(CanopyColor.primaryForeground)
            .padding(.horizontal, CanopySpacing.x6)
            .padding(.vertical, CanopySpacing.x3)
            .background(CanopyColor.primary)
            .clipShape(Capsule())
            .shadow(color: CanopyColor.overlay.opacity(0.25), radius: 12, y: 6)
        }
        .accessibilityLabel("Resume dictating this note")
    }

    /// The simple play / stop control for the note's recording. Play / stop only - no scrubbing or
    /// rate controls (spec 0007 keeps detail playback minimal).
    private var playButton: some View {
        Button {
            playback.toggle()
        } label: {
            HStack(spacing: CanopySpacing.x2) {
                Image(systemName: playback.isPlaying ? "stop.fill" : "play.fill")
                Text(playback.isPlaying ? "Stop" : "Play recording")
                    .font(.system(size: CanopyFont.sizeSm, weight: .semibold))
            }
            .foregroundStyle(CanopyColor.primaryForeground)
            .padding(.horizontal, CanopySpacing.x4)
            .padding(.vertical, CanopySpacing.x2)
            .background(CanopyColor.primary)
            .clipShape(Capsule())
        }
        .accessibilityLabel(playback.isPlaying ? "Stop recording" : "Play recording")
    }

    private func beginEdit() {
        draft = paragraphs.joined(separator: "\n\n")
        isEditing = true
        editorFocused = true
    }

    private func commitEdit() {
        paragraphs = Note.splitParagraphs(draft)
        isEditing = false
        editorFocused = false
        onCommitEdit?(currentNote)
    }
}

#Preview {
    NavigationStack {
        NoteDetailView(note: MockNotes.all[0], resolver: StoreAudioURLResolver(store: NoteStore()))
    }
}
