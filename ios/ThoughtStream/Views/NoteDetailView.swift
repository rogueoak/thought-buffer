import SwiftUI
import UIKit

/// Detail for a single note: its paragraphs and timestamp, themed. When the note carries a recording
/// (spec 0007), a simple Play / Stop control plays it back in full. The text is editable with the
/// keyboard, and a Resume action reopens the note into a recording session to keep dictating
/// (feedback 0008).
struct NoteDetailView: View {
    let note: Note
    @StateObject private var playback: NotePlaybackModel
    // This view only EMITS intents (`onCommitEdit`/`onDiscardEmpty`); the composition root
    // (`StreamListView`) owns the actual store write/delete and the route pop. The draft/editing
    // `@State` stays local so per-note editing is not reworked into the root.
    @Environment(\.scenePhase) private var scenePhase

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
    /// Called when a brand-new note (spec 0013) is abandoned with no title and no body, so the
    /// composition root discards it (never persists it, or deletes it if it was provisionally saved)
    /// rather than leaving a blank note in the list. Nil for a normal saved note.
    private let onDiscardEmpty: (() -> Void)?
    /// Whether this note is a brand-new, not-yet-persisted note opened straight into the editor
    /// (spec 0013). It stays true until the first non-empty commit persists real content; while true,
    /// leaving with no title and no body discards the note via `onDiscardEmpty`.
    @State private var isUnsavedNewNote: Bool

    /// The note's paragraphs as shown/edited. Seeded from the note; edits mutate this and, on commit,
    /// build an updated note handed back through `onCommitEdit`.
    @State private var paragraphs: [String]
    @State private var isEditing: Bool
    @State private var draft: String
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

    /// Whether the "copied to clipboard" confirmation chip is currently shown (spec 0017). Set true
    /// when Copy text runs, cleared after a brief delay so the chip is transient like the dictation
    /// command chips.
    @State private var showCopiedConfirmation = false

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
        onCommitEdit: ((Note) -> Void)? = nil,
        onDiscardEmpty: (() -> Void)? = nil,
        startInEdit: Bool = false
    ) {
        self.note = note
        self.onNewThought = onNewThought
        self.onOpenSettings = onOpenSettings
        self.onResume = onResume
        self.onCommitEdit = onCommitEdit
        self.onDiscardEmpty = onDiscardEmpty
        _paragraphs = State(initialValue: note.paragraphs)
        _hasCustomTitle = State(initialValue: note.hasCustomTitle)
        _customTitleText = State(initialValue: note.title)
        // A brand-new note (spec 0013) opens straight into the body editor and is unsaved until the
        // first non-empty commit. `startInEdit` drives both: the editor opens focused, and the note is
        // tracked as unsaved so backing out untouched discards it.
        _isEditing = State(initialValue: startInEdit)
        _draft = State(initialValue: startInEdit ? note.paragraphs.joined(separator: "\n\n") : "")
        _isUnsavedNewNote = State(initialValue: startInEdit)
        // The full note is passed through so the shared playback controller titles the system Now
        // Playing item (lock screen / Control Center) and reads the recording duration.
        let controller = controller ?? NotePlaybackController(resolver: resolver, player: player)
        _playback = StateObject(wrappedValue: NotePlaybackModel(note: note, controller: controller))
    }

    var body: some View {
        ZStack {
            // A background tap while editing the title resigns its focus, which commits it via the
            // `titleFocused` observer below (feedback 0014): tapping the empty area around the note now
            // saves the title just like Done. Gated on `isEditingTitle` so it is inert in the normal
            // read/body-edit states, and `simultaneous` so it never steals a tap from the note text,
            // its buttons, or the title field itself (those have their own gestures / begin body edit).
            CanopyColor.bg.ignoresSafeArea()
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        if isEditingTitle { titleFocused = false }
                    },
                    isEnabled: isEditingTitle
                )

            ScrollView {
                VStack(alignment: .leading, spacing: CanopySpacing.x4) {
                    titleHeader

                    // The metadata line is shared with the list card via `NoteMetaStats`: the duration
                    // now uses the SAME timer glyph and tight `x1` spacing as the card instead of a dash
                    // separator (feedback 0015), so the detail header and the card present it identically.
                    NoteMetaStats(note: currentNote)
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

            // The transient "Copied to clipboard" confirmation (spec 0017), styled like the dictation
            // command chips (muted capsule). Pinned near the bottom so it does not cover the note text
            // or the toolbar; it fades in on Copy and out after a moment.
            if showCopiedConfirmation {
                VStack {
                    Spacer()
                    copiedConfirmationChip
                        .padding(.bottom, CanopySpacing.x8)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showCopiedConfirmation)
        // Resume sits centered at the bottom of the screen (feedback 0008), clear of the scrolling
        // note body. Hidden while editing text, and only when a call site can reopen a session.
        .safeAreaInset(edge: .bottom) {
            // Hide the record affordance while a brand-new note is still empty (spec 0013): there is
            // nothing to record onto yet, and it would race the discard-on-leave. It appears once the
            // note has content (committed, so no longer unsaved).
            if let onResume, !isEditingAnything, !isUnsavedNewNote {
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
                // The "..." actions menu (spec 0017): Share sends the note's plain text through the
                // system share sheet, Copy text puts the same text on the pasteboard. Both read
                // `currentNote.shareableText` so they are identical and reflect any in-view edits
                // already folded into `currentNote`. Only shown in the normal (non-editing) state.
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ShareLink(item: currentNote.shareableText) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        Button(action: copyNoteText) {
                            Label("Copy text", systemImage: "doc.on.doc")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .tint(CanopyColor.primary)
                    .accessibilityLabel("Note actions")
                }
            }
        }
        // A brand-new note (spec 0013) opens with the body editor focused so the user can type at once.
        // Focus is set here (not in init) because a FocusState only takes effect once the view exists.
        .onAppear { if isUnsavedNewNote { editorFocused = true } }
        // Stop playback if the user navigates away mid-play, so audio never keeps running off-screen.
        // Also finalize a brand-new note the user backed out of WITHOUT tapping Done (spec 0013):
        // keep it if anything was typed (auto-save, so typed content is never lost on back), discard it
        // only if still blank. A committed note has cleared `isUnsavedNewNote` already.
        .onDisappear {
            playback.stop()
            if isUnsavedNewNote { finalizeUnsavedNote() }
        }
        // `onDisappear` covers back-navigation but does NOT fire on app suspend/terminate, so a typed
        // brand-new note could otherwise be lost if the app is backgrounded before Done or back (spec
        // 0013). Observe the scene phase: on the way to background/inactive, finalize an unsaved new
        // note (persist typed content, or discard a still-blank one). `finalizeUnsavedNote` clears
        // `isUnsavedNewNote` before it acts, so a following back-navigation cannot persist/pop twice.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active, isUnsavedNewNote { finalizeUnsavedNote() }
        }
        // Tapping out of the title field saves it - no Done required (feedback 0014). The title field
        // loses focus whenever the user taps elsewhere (the background tap below, or into the body,
        // which resigns the field). Committing on that focus loss makes "tap away" behave exactly like
        // Done: `commitTitle` reads the LIVE `titleDraft` (never a stale `paragraphs`-derived value), so
        // in-flight text is never dropped. Guarded on `isEditingTitle` so `commitTitle`'s own
        // `titleFocused = false` cannot re-enter, and so losing body focus never triggers a title commit.
        .onChange(of: titleFocused) { _, focused in
            if !focused, isEditingTitle { commitTitle() }
        }
    }

    /// Whether the user is editing the body OR the title, so read-mode affordances (mic/gear, Resume)
    /// hide and the Done button shows for either.
    private var isEditingAnything: Bool { isEditing || isEditingTitle }

    /// The note as it currently stands (edits applied). The rebuild lives in a pure model helper
    /// (`Note.editedCopy`) so the recording, timings, AND `folderPath` are all preserved in one place:
    /// dropping `folderPath` here would make `NoteStore.save` re-file every foldered note to the root
    /// on commit. The title is the user's custom one when set, else re-derived from the first sentence
    /// so it tracks body edits (spec 0009). Handed to `onCommitEdit` and `onResume`.
    private var currentNote: Note {
        note.editedCopy(
            paragraphs: paragraphs,
            hasCustomTitle: hasCustomTitle,
            customTitle: customTitleText
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

    /// The record affordance (reopen the note into a dictation session), styled as a prominent pill
    /// for the bottom bar. Labeled "Record" when the note has no audio yet - tapping it captures a
    /// real recording (spec 0013) - and "Resume" once it already carries a recording (feedback 0008).
    private func resumeButton(action: @escaping () -> Void) -> some View {
        let hasAudio = currentNote.hasAudio
        let title = hasAudio ? "Resume" : "Record"
        return Button(action: action) {
            HStack(spacing: CanopySpacing.x2) {
                Image(systemName: "mic.fill")
                Text(title)
                    .font(.system(size: CanopyFont.sizeBase, weight: .semibold))
            }
            .foregroundStyle(CanopyColor.primaryForeground)
            .padding(.horizontal, CanopySpacing.x6)
            .padding(.vertical, CanopySpacing.x3)
            .background(CanopyColor.primary)
            .clipShape(Capsule())
            .shadow(color: CanopyColor.overlay.opacity(0.25), radius: 12, y: 6)
        }
        .accessibilityLabel(hasAudio ? "Resume dictating this note" : "Record audio for this note")
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

    /// The transient "Copied to clipboard" confirmation chip (spec 0017), reusing the muted-capsule
    /// styling of the dictation command chips so the app's feedback looks consistent.
    private var copiedConfirmationChip: some View {
        HStack(spacing: CanopySpacing.x2) {
            Image(systemName: "doc.on.doc")
            Text("Copied to clipboard")
                .font(.system(size: CanopyFont.sizeSm, weight: .semibold))
        }
        .font(.system(size: CanopyFont.sizeSm))
        .foregroundStyle(CanopyColor.mutedForeground)
        .padding(.horizontal, CanopySpacing.x4)
        .padding(.vertical, CanopySpacing.x2)
        .background(CanopyColor.muted)
        .clipShape(Capsule())
        .shadow(color: CanopyColor.overlay.opacity(0.2), radius: 8, y: 4)
        .accessibilityLabel("Copied to clipboard")
    }

    /// Copy the note's shareable plain text to the system pasteboard and flash the confirmation chip
    /// (spec 0017). Uses the SAME `currentNote.shareableText` the share sheet sends, so Share and Copy
    /// never diverge. The chip auto-hides after a short delay.
    private func copyNoteText() {
        UIPasteboard.general.string = currentNote.shareableText
        showCopiedConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            showCopiedConfirmation = false
        }
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
        persistOrDiscard()
    }

    private func commitEdit() {
        paragraphs = Note.splitParagraphs(draft)
        isEditing = false
        editorFocused = false
        persistOrDiscard()
    }

    /// Commit an edit: persist the note through `onCommitEdit`, unless this is a brand-new note left
    /// with no title and no body (spec 0013), in which case discard it so no blank note is saved. Once
    /// a new note has real content, it is persisted and stops being tracked as unsaved.
    private func persistOrDiscard() {
        if isUnsavedNewNote, isEmptyNewNote {
            // Nothing typed into the fresh note: discard rather than persist a blank note. Clear the
            // flag so a following `onDisappear` cannot discard (and pop) a second time.
            isUnsavedNewNote = false
            onDiscardEmpty?()
            return
        }
        isUnsavedNewNote = false
        onCommitEdit?(currentNote)
    }

    /// Finalize a fresh note the user left without tapping Done: fold any in-progress body/title edit
    /// into the model first (the typed text lives in `draft`/`titleDraft`, not yet in `paragraphs`),
    /// then persist it if it has content or discard it if still blank (spec 0013). This is what keeps
    /// typed-but-not-committed content from being lost on a back-navigation.
    private func finalizeUnsavedNote() {
        if isEditing { paragraphs = Note.splitParagraphs(draft) }
        if isEditingTitle {
            let resolved = Note.resolveTitleEdit(
                rawTitle: titleDraft,
                paragraphs: paragraphs,
                createdAt: note.createdAt
            )
            customTitleText = resolved.title
            hasCustomTitle = resolved.isCustom
        }
        persistOrDiscard()
    }

    /// Whether a brand-new note is still a blank draft: no body text and no user-entered custom title.
    /// The rule lives in a pure model helper (`Note.isBlankDraft`) so it is unit-tested, not trapped in
    /// view state (the spec 0009 `resolveTitleEdit` precedent). A title-only new note counts as content
    /// (kept, not discarded): a user who dismisses the body editor and types only a title still has
    /// their note saved. That path is reachable because the title stays tappable once `!isEditing`.
    private var isEmptyNewNote: Bool {
        Note.isBlankDraft(
            paragraphs: paragraphs,
            hasCustomTitle: hasCustomTitle,
            customTitle: customTitleText
        )
    }
}

#Preview {
    NavigationStack {
        NoteDetailView(note: MockNotes.all[0], resolver: StoreAudioURLResolver(store: NoteStore()))
    }
}
