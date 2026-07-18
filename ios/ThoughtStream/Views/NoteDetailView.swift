import SwiftUI

/// Detail for a single note: its paragraphs and timestamp, themed. When the note carries a recording
/// (spec 0007), a simple Play / Stop control plays it back in full. The text is editable with the
/// keyboard, and a Resume action reopens the note into a recording session to keep dictating
/// (feedback 0008).
struct NoteDetailView: View {
    let note: Note
    @StateObject private var playback: NotePlaybackModel

    /// Called when the user taps the toolbar mic to start a fresh thought (feedback 0011), so the
    /// composition root requests a new session through the same route the list uses. Nil at
    /// bare/preview call sites (no mic shown).
    private let onNewThought: (() -> Void)?
    /// Called when the user taps the toolbar gear (feedback 0011), so the composition root opens
    /// Settings. Nil at bare/preview call sites (no gear shown).
    private let onOpenSettings: (() -> Void)?
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

    /// Whether the title is user-set (spec 0009). When false, the shown title derives from the first
    /// sentence and tracks body edits; when true, `customTitleText` is the title and body edits leave
    /// it alone. Seeded from the note; committed back through `currentNote`.
    @State private var hasCustomTitle: Bool
    /// The user's custom title, used only when `hasCustomTitle`. Seeded from the note's title so
    /// editing a derived title starts from the current text.
    @State private var customTitleText: String
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

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
        onNewThought: (() -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil,
        onResume: ((Note) -> Void)? = nil,
        onCommitEdit: ((Note) -> Void)? = nil
    ) {
        self.note = note
        self.onNewThought = onNewThought
        self.onOpenSettings = onOpenSettings
        self.onResume = onResume
        self.onCommitEdit = onCommitEdit
        _paragraphs = State(initialValue: note.paragraphs)
        _hasCustomTitle = State(initialValue: note.hasCustomTitle)
        _customTitleText = State(initialValue: note.title)
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
                    titleHeader

                    HStack(spacing: CanopySpacing.x2) {
                        Image(systemName: "clock")
                        // Same live-reference fix as the note card (feedback 0011): without a
                        // TimelineView this label freezes at render and only looked correct because the
                        // detail page is rebuilt on each navigation - it would go stale if left open.
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(RelativeTime.label(for: note.createdAt, relativeTo: context.date))
                        }
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
                        // Symmetric to the title gate: the body is only tappable-to-edit when not
                        // already editing the title, so the two edit modes never overlap.
                        .onTapGesture { if onCommitEdit != nil, !isEditingTitle { beginEdit() } }
                        .accessibilityAddTraits(onCommitEdit != nil && !isEditingTitle ? .isButton : [])
                        .accessibilityHint(onCommitEdit != nil && !isEditingTitle ? "Double tap to edit" : "")
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
            if let onResume, !isEditingAnything {
                resumeButton { onResume(currentNote) }
                    .padding(.bottom, CanopySpacing.x4)
            }
        }
        .navigationTitle(currentNote.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Editing starts by tapping the note text or its title (feedback 0010, spec 0009), so there
            // is no read-mode Edit button; the toolbar shows only a Done button WHILE editing either, to
            // commit. Gated on the call site being able to persist the result (`onCommitEdit` supplied).
            if onCommitEdit != nil, isEditingAnything {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isEditingTitle ? commitTitle() : commitEdit() }
                        .tint(CanopyColor.primary)
                }
            }
            // Mic + gear on the note page (feedback 0011): start a new thought or open Settings in one
            // tap, mirroring the Stream toolbar. Hidden while editing (Done owns the trailing slot then)
            // and only where the call site can act on them.
            if !isEditingAnything {
                if let onNewThought {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onNewThought) {
                            Image(systemName: "mic.fill")
                        }
                        .tint(CanopyColor.primary)
                        .accessibilityLabel("Start a new thought")
                    }
                }
                if let onOpenSettings {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onOpenSettings) {
                            Image(systemName: "gearshape")
                        }
                        .tint(CanopyColor.primary)
                        .accessibilityLabel("Settings")
                    }
                }
            }
        }
        // Stop playback if the user navigates away mid-play, so audio never keeps running off-screen.
        .onDisappear { playback.stop() }
    }

    /// Whether the user is editing the body OR the title, so read-mode affordances (mic/gear, Resume)
    /// hide and the Done button shows for either.
    private var isEditingAnything: Bool { isEditing || isEditingTitle }

    /// The note as it currently stands (edits applied), with the recording/timings preserved. The
    /// title is the user's custom one when set, else re-derived from the first sentence so it tracks
    /// body edits (spec 0009). Handed to `onCommitEdit` and `onResume`.
    private var currentNote: Note {
        let effectiveTitle = hasCustomTitle
            ? customTitleText
            : Note.deriveTitle(paragraphs: paragraphs, createdAt: note.createdAt)
        return Note(
            id: note.id,
            title: effectiveTitle,
            paragraphs: paragraphs,
            createdAt: note.createdAt,
            hasCustomTitle: hasCustomTitle,
            audioFileName: note.audioFileName,
            // An edit can shrink the paragraph count; cap timings so the note never carries more
            // timings than paragraphs (parity with the record-screen edit; engineer review).
            timings: Array(note.timings.prefix(paragraphs.count))
        )
    }

    /// The note title at the top of the page: a prominent header the user can edit independent of the
    /// body (spec 0009). Tapping it (only where the call site can persist) swaps in a text field; a
    /// non-empty commit sets a custom title, an empty commit resets to the derived first sentence.
    @ViewBuilder
    private var titleHeader: some View {
        if isEditingTitle {
            TextField("Title", text: $titleDraft)
                .focused($titleFocused)
                .font(.system(size: CanopyFont.sizeXl, weight: .bold))
                .foregroundStyle(CanopyColor.text)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)
                .onSubmit { commitTitle() }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(currentNote.title)
                .font(.system(size: CanopyFont.sizeXl, weight: .bold))
                .foregroundStyle(CanopyColor.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // Title and body editing are MUTUALLY EXCLUSIVE (engineer review): entering title
                // edit while the body editor is open would commit via `currentNote` (built from
                // `paragraphs`, not the in-flight `draft`) and drop freshly typed body text. So the
                // title is only tappable when not already editing the body; Done exits one first.
                .onTapGesture { if onCommitEdit != nil, !isEditing { beginEditTitle() } }
                .accessibilityAddTraits(onCommitEdit != nil && !isEditing ? .isButton : [])
                .accessibilityHint(onCommitEdit != nil && !isEditing ? "Double tap to edit the title" : "")
        }
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

    private func beginEditTitle() {
        // Seed from the currently shown title (derived or custom) so the user tweaks what they see.
        titleDraft = currentNote.title
        isEditingTitle = true
        titleFocused = true
    }

    private func commitTitle() {
        // The reset/set rule lives in a pure, tested model helper (spec 0009): a blank entry resets to
        // the derived first sentence (non-custom), anything else is a custom title.
        let resolved = Note.resolveTitleEdit(
            rawTitle: titleDraft,
            paragraphs: paragraphs,
            createdAt: note.createdAt
        )
        customTitleText = resolved.title
        hasCustomTitle = resolved.isCustom
        isEditingTitle = false
        titleFocused = false
        onCommitEdit?(currentNote)
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
