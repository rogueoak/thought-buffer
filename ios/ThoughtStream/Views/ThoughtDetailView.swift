import SwiftUI

/// Detail for a single thought: its paragraphs and timestamp, themed. When the thought carries a recording
/// (spec 0007), a simple Play / Stop control plays it back in full. The text is editable with the
/// keyboard, and a Resume action reopens the thought into a recording session to keep dictating
/// (feedback 0008).
struct ThoughtDetailView: View {
    let thought: Thought
    @StateObject private var playback: ThoughtPlaybackModel
    // This view only EMITS intents (`onCommitEdit`/`onDiscardEmpty`); the composition root
    // (`StreamListView`) owns the actual store write/delete and the route pop. The draft/editing
    // `@State` stays local so per-thought editing is not reworked into the root.
    @Environment(\.scenePhase) private var scenePhase

    /// Called when the user taps the toolbar mic to start a fresh thought (feedback 0011), carrying a
    /// folder path so the new thought is filed contextually (this thought's folder), not at the root. Nil at
    /// bare/preview call sites (no mic shown).
    private let onNewThought: (([String]) -> Void)?
    /// Called when the user taps the toolbar gear (feedback 0011), so the composition root opens
    /// Settings. Nil at bare/preview call sites (no gear shown).
    private let onOpenSettings: (() -> Void)?
    /// Called with the current thought when the user taps Resume, so the composition root can reopen a
    /// recording session seeded with it. Nil at bare/preview call sites (no Resume affordance shown).
    private let onResume: ((Thought) -> Void)?
    /// Called with the edited thought when the user commits a keyboard edit, so the composition root can
    /// persist it and refresh the feed. Nil at bare/preview call sites (editing then shows no Save).
    private let onCommitEdit: ((Thought) -> Void)?
    /// Called when a brand-new thought (spec 0013) is abandoned with no title and no body, so the
    /// composition root discards it (never persists it, or deletes it if it was provisionally saved)
    /// rather than leaving a blank thought in the list. Nil for a normal saved thought.
    private let onDiscardEmpty: (() -> Void)?
    /// Called with this thought's id when the user taps Delete in the "..." menu (spec 0020), so the
    /// composition root soft-deletes it through the shared undoable path AND pops back to the list where
    /// the undo affordance is visible. Nil at bare/preview call sites (no Delete shown).
    private let onDelete: ((UUID) -> Void)?
    /// Called with a search query typed into the persistent bottom bar's search field (spec 0021), so
    /// the composition root routes to the SAME global results the list shows - search is reachable from
    /// the thought page too. Nil at bare/preview call sites (the bottom bar then omits the field).
    private let onSearch: ((String) -> Void)?
    /// Whether the resume icon applies for this thought per the audio-retention setting (spec 0021):
    /// resuming an existing recording always applies; recording onto a text-only thought applies only when
    /// the retention policy records audio. Computed by the composition root and passed in so the pure
    /// decision is not re-derived in the view. When false, the bottom bar omits the resume icon.
    private let resumeApplies: Bool
    /// Whether this thought is a brand-new, not-yet-persisted thought opened straight into the editor
    /// (spec 0013). It stays true until the first non-empty commit persists real content; while true,
    /// leaving with no title and no body discards the thought via `onDiscardEmpty`.
    @State private var isUnsavedNewThought: Bool

    /// The thought's paragraphs as shown/edited. Seeded from the thought; edits mutate this and, on commit,
    /// build an updated thought handed back through `onCommitEdit`.
    @State private var paragraphs: [String]
    @State private var isEditing: Bool
    @State private var draft: String
    @FocusState private var editorFocused: Bool

    /// Whether the title is user-set (spec 0009). When false, the shown title derives from the first
    /// sentence and tracks body edits; when true, `customTitleText` is the title and body edits leave
    /// it alone. Seeded from the thought; committed back through `currentThought`.
    @State private var hasCustomTitle: Bool
    /// The user's custom title, used only when `hasCustomTitle`. Seeded from the thought's title so
    /// editing a derived title starts from the current text.
    @State private var customTitleText: String
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    /// Drives the shared "Copied to clipboard" confirmation (spec 0017): `copiedTrigger` is bumped by
    /// Copy text so the lifecycle-tied `copiedConfirmation` modifier (re)arms its auto-hide, and
    /// `showCopiedConfirmation` holds the chip's current visibility.
    @State private var copiedTrigger = 0
    @State private var showCopiedConfirmation = false

    /// The live query typed into the persistent bottom bar's search field (spec 0021). Because search is
    /// GLOBAL and presented as a flat list on the folder screens, a non-empty query here routes to the
    /// list results via `onSearch` (popping back to the list) - this view does not render its own
    /// results. Kept local so the field is inert on a bare/preview call site.
    @State private var searchQuery = ""

    /// Build the detail view. Prefers the ONE shared `ThoughtPlaybackController` (so the phone and
    /// CarPlay drive the same media center and never race); when none is supplied - a preview, a
    /// screenshot build, or a bare call site - it falls back to a private controller over the given
    /// `resolver`, which resolves the recording lazily (off the main actor, at play time) so
    /// navigation never blocks on the coordinated presence check. When the thought claims no audio, no
    /// play affordance shows.
    init(
        thought: Thought,
        resolver: AudioURLResolving,
        player: AudioThoughtPlayer? = nil,
        controller: ThoughtPlaybackController? = nil,
        onNewThought: (([String]) -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil,
        onResume: ((Thought) -> Void)? = nil,
        onCommitEdit: ((Thought) -> Void)? = nil,
        onDiscardEmpty: (() -> Void)? = nil,
        onDelete: ((UUID) -> Void)? = nil,
        onSearch: ((String) -> Void)? = nil,
        resumeApplies: Bool = true,
        startInEdit: Bool = false
    ) {
        self.thought = thought
        self.onNewThought = onNewThought
        self.onOpenSettings = onOpenSettings
        self.onResume = onResume
        self.onCommitEdit = onCommitEdit
        self.onDiscardEmpty = onDiscardEmpty
        self.onDelete = onDelete
        self.onSearch = onSearch
        self.resumeApplies = resumeApplies
        _paragraphs = State(initialValue: thought.paragraphs)
        _hasCustomTitle = State(initialValue: thought.hasCustomTitle)
        _customTitleText = State(initialValue: thought.title)
        // A brand-new thought (spec 0013) opens straight into the body editor and is unsaved until the
        // first non-empty commit. `startInEdit` drives both: the editor opens focused, and the thought is
        // tracked as unsaved so backing out untouched discards it.
        _isEditing = State(initialValue: startInEdit)
        _draft = State(initialValue: startInEdit ? thought.paragraphs.joined(separator: "\n\n") : "")
        _isUnsavedNewThought = State(initialValue: startInEdit)
        // The full thought is passed through so the shared playback controller titles the system Now
        // Playing item (lock screen / Control Center) and reads the recording duration.
        let controller = controller ?? ThoughtPlaybackController(resolver: resolver, player: player)
        _playback = StateObject(wrappedValue: ThoughtPlaybackModel(thought: thought, controller: controller))
    }

    var body: some View {
        ZStack {
            // A background tap while editing the title resigns its focus, which commits it via the
            // `titleFocused` observer below (feedback 0014): tapping the empty area around the thought now
            // saves the title just like Done. Gated on `isEditingTitle` so it is inert in the normal
            // read/body-edit states, and `simultaneous` so it never steals a tap from the thought text,
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

                    // The metadata line is shared with the list card via `ThoughtMetaStats`: the duration
                    // now uses the SAME timer glyph and tight `x1` spacing as the card instead of a dash
                    // separator (feedback 0015), so the detail header and the card present it identically.
                    ThoughtMetaStats(thought: currentThought)
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
                        // Tap the text to edit (feedback 0010): the thought body IS the edit affordance,
                        // so the separate Edit button is gone. Only tappable where the call site can
                        // persist the result (`onCommitEdit` supplied); a bare/preview thought stays read
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
                        // Tapping the body from the title commits the title FIRST, then begins body
                        // editing in the SAME tap (feedback 0014): the two edit modes never overlap
                        // because `beginBodyEditFromTap` folds any in-flight title edit in before it
                        // opens the body editor, so no second tap is needed.
                        .onTapGesture { if onCommitEdit != nil { beginBodyEditFromTap() } }
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
        // The transient "Copied to clipboard" confirmation (spec 0017), from the shared, lifecycle-tied
        // modifier so a rapid double-copy re-arms it and navigation cancels its timer. Pinned near the
        // bottom so it clears the thought text and the toolbar.
        .copiedConfirmation(trigger: copiedTrigger, isShown: $showCopiedConfirmation, alignment: .bottom)
        // The persistent bottom bar (spec 0021): a wide search field on the left, the resume icon on the
        // right. Search is global, so a query here routes to the list results via `onSearch`. Which
        // affordances show - and whether the bar shows at all - is the pure, tested `ThoughtDetailBottomBar`
        // decision: it is HIDDEN entirely while editing the title or body, so the search field never
        // renders under the keyboard and a brand-new thought does not present two competing text fields. The
        // bar reuses the SAME component the list uses (not a fork).
        .safeAreaInset(edge: .bottom) {
            if bottomBarLayout.isVisible {
                bottomBar
                    .padding(.bottom, CanopySpacing.x2)
            }
        }
        .navigationTitle(currentThought.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Editing starts by tapping the thought text or its title (feedback 0010, spec 0009), so there
            // is no read-mode Edit button; the toolbar shows only a Done button WHILE editing either, to
            // commit. Gated on the call site being able to persist the result (`onCommitEdit` supplied).
            if onCommitEdit != nil, isEditingAnything {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isEditingTitle ? commitTitle() : commitEdit() }
                        .tint(CanopyColor.primary)
                }
            }
            // Mic + gear on the thought page (feedback 0011): start a new thought or open Settings in one
            // tap, mirroring the Stream toolbar. Hidden while editing (Done owns the trailing slot then)
            // and only where the call site can act on them.
            if !isEditingAnything {
                if let onNewThought {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            // File the new thought in THIS thought's folder (contextual), not the root.
                            onNewThought(thought.folderPath)
                        } label: {
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
                // The "..." actions menu (spec 0017): Share + Copy text from the ONE shared
                // `ThoughtActionsMenu`, on `currentThought` so both reflect any in-view edits already folded
                // into it. Only shown in the normal (non-editing) state. `onCopied` bumps the trigger
                // that flashes the shared confirmation chip.
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ThoughtActionsMenu(thought: currentThought, onCopied: { copiedTrigger += 1 }) {
                            // Delete (spec 0020) via the shared undoable path: the composition root
                            // soft-deletes and pops back to the list where the undo affordance shows.
                            // Only when a call site supplied `onDelete` (a bare/preview thought has none).
                            if let onDelete {
                                Button(role: .destructive) {
                                    onDelete(thought.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .tint(CanopyColor.primary)
                    .accessibilityLabel("Thought actions")
                }
            }
        }
        // A brand-new thought (spec 0013) opens with the body editor focused so the user can type at once.
        // Focus is set here (not in init) because a FocusState only takes effect once the view exists.
        .onAppear { if isUnsavedNewThought { editorFocused = true } }
        // Stop playback if the user navigates away mid-play, so audio never keeps running off-screen.
        // Also finalize a brand-new thought the user backed out of WITHOUT tapping Done (spec 0013):
        // keep it if anything was typed (auto-save, so typed content is never lost on back), discard it
        // only if still blank. A committed thought has cleared `isUnsavedNewThought` already.
        .onDisappear {
            playback.stop()
            if isUnsavedNewThought { finalizeUnsavedThought() }
        }
        // `onDisappear` covers back-navigation but does NOT fire on app suspend/terminate, so a typed
        // brand-new thought could otherwise be lost if the app is backgrounded before Done or back (spec
        // 0013). Observe the scene phase: on the way to background/inactive, finalize an unsaved new
        // thought (persist typed content, or discard a still-blank one). `finalizeUnsavedThought` clears
        // `isUnsavedNewThought` before it acts, so a following back-navigation cannot persist/pop twice.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active, isUnsavedNewThought { finalizeUnsavedThought() }
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

    /// The thought as it currently stands (edits applied). The rebuild lives in a pure model helper
    /// (`Thought.editedCopy`) so the recording, timings, AND `folderPath` are all preserved in one place:
    /// dropping `folderPath` here would make `ThoughtStore.save` re-file every foldered thought to the root
    /// on commit. The title is the user's custom one when set, else re-derived from the first sentence
    /// so it tracks body edits (spec 0009). Handed to `onCommitEdit` and `onResume`.
    private var currentThought: Thought {
        thought.editedCopy(
            paragraphs: paragraphs,
            hasCustomTitle: hasCustomTitle,
            customTitle: customTitleText
        )
    }

    /// The thought title at the top of the page: a prominent header the user can edit independent of the
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
            Text(currentThought.title)
                .font(.system(size: CanopyFont.sizeXl, weight: .bold))
                .foregroundStyle(CanopyColor.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // Title and body editing are MUTUALLY EXCLUSIVE (engineer review): entering title
                // edit while the body editor is open would commit via `currentThought` (built from
                // `paragraphs`, not the in-flight `draft`) and drop freshly typed body text. So the
                // title is only tappable when not already editing the body; Done exits one first.
                .onTapGesture { if onCommitEdit != nil, !isEditing { beginEditTitle() } }
                .accessibilityAddTraits(onCommitEdit != nil && !isEditing ? .isButton : [])
                .accessibilityHint(onCommitEdit != nil && !isEditing ? "Double tap to edit the title" : "")
        }
    }

    /// The pure decision for what the thought-detail bottom bar shows (spec 0021), extracted into the tested
    /// `ThoughtDetailBottomBar` seam so the "hidden while editing / search / resume" logic is not re-derived
    /// inline. The `.safeAreaInset` gate and the `bottomBar` body both read from this one decision.
    private var bottomBarLayout: ThoughtDetailBottomBar {
        ThoughtDetailBottomBar.decide(
            canSearch: onSearch != nil,
            canResume: onResume != nil,
            resumeApplies: resumeApplies,
            isEditing: isEditingAnything,
            isUnsavedNewThought: isUnsavedNewThought
        )
    }

    /// The persistent bottom bar for the thought page (spec 0021): the SAME `BottomBar` component the list
    /// uses, with a search field and a resume icon on the right. What it shows is the pure
    /// `bottomBarLayout` decision (search when the call site can route one; resume when a session can be
    /// reopened, resuming applies, and the thought is not a still-empty new thought; hidden entirely while
    /// editing).
    private var bottomBar: some View {
        let layout = bottomBarLayout
        // Submitting a non-empty query routes to the SAME global results the folder screens render (spec
        // 0021): the composition root pops back to the list and applies the query there, so search from
        // the thought page behaves identically. Routing on SUBMIT (not every keystroke) lets the user type a
        // multi-character query on the thought page before it pops - a per-keystroke route would tear this
        // view down on the first character.
        return BottomBar(
            query: $searchQuery,
            showsSearchField: layout.showsSearch,
            onSubmit: {
                if ThoughtSearch.isActive(searchQuery) { onSearch?(searchQuery) }
            }
        ) {
            if layout.showsResume {
                BottomBarRecordButton(accessibilityLabel: resumeAccessibilityLabel) {
                    onResume?(currentThought)
                }
            }
        }
    }

    /// The resume icon's accessibility label (the text label is dropped in the bottom bar, spec 0021):
    /// "Resume recording" for a thought that already carries audio, else "Record audio for this thought".
    private var resumeAccessibilityLabel: String {
        currentThought.hasAudio ? "Resume recording" : "Record audio for this thought"
    }

    /// The simple play / stop control for the thought's recording. Play / stop only - no scrubbing or
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

    /// Begin body editing from a tap on the body (feedback 0014). If the title was being edited, commit
    /// it FIRST so its typed text is saved and the two edit modes never overlap, then open the body
    /// editor - all in the one tap, so no second tap is needed. `commitTitle` reads the live
    /// `titleDraft` and folds it into `paragraphs`-independent title state, and `beginEdit` seeds the
    /// body draft from the (unchanged) `paragraphs`, so nothing is lost across the handoff.
    private func beginBodyEditFromTap() {
        if isEditingTitle { commitTitle() }
        beginEdit()
    }

    private func beginEditTitle() {
        // Seed from the currently shown title (derived or custom) so the user tweaks what they see.
        titleDraft = currentThought.title
        isEditingTitle = true
        titleFocused = true
    }

    private func commitTitle() {
        // The reset/set rule lives in a pure, tested model helper (spec 0009): a blank entry resets to
        // the derived first sentence (non-custom), anything else is a custom title.
        let resolved = Thought.resolveTitleEdit(
            rawTitle: titleDraft,
            paragraphs: paragraphs,
            createdAt: thought.createdAt
        )
        customTitleText = resolved.title
        hasCustomTitle = resolved.isCustom
        isEditingTitle = false
        titleFocused = false
        persistOrDiscard()
    }

    private func commitEdit() {
        paragraphs = Thought.splitParagraphs(draft)
        isEditing = false
        editorFocused = false
        persistOrDiscard()
    }

    /// Commit an edit: persist the thought through `onCommitEdit`, unless this is a brand-new thought left
    /// with no title and no body (spec 0013), in which case discard it so no blank thought is saved. Once
    /// a new thought has real content, it is persisted and stops being tracked as unsaved.
    private func persistOrDiscard() {
        if isUnsavedNewThought, isEmptyNewThought {
            // Nothing typed into the fresh thought: discard rather than persist a blank thought. Clear the
            // flag so a following `onDisappear` cannot discard (and pop) a second time.
            isUnsavedNewThought = false
            onDiscardEmpty?()
            return
        }
        isUnsavedNewThought = false
        onCommitEdit?(currentThought)
    }

    /// Finalize a fresh thought the user left without tapping Done: fold any in-progress body/title edit
    /// into the model first (the typed text lives in `draft`/`titleDraft`, not yet in `paragraphs`),
    /// then persist it if it has content or discard it if still blank (spec 0013). This is what keeps
    /// typed-but-not-committed content from being lost on a back-navigation.
    private func finalizeUnsavedThought() {
        if isEditing { paragraphs = Thought.splitParagraphs(draft) }
        if isEditingTitle {
            let resolved = Thought.resolveTitleEdit(
                rawTitle: titleDraft,
                paragraphs: paragraphs,
                createdAt: thought.createdAt
            )
            customTitleText = resolved.title
            hasCustomTitle = resolved.isCustom
        }
        persistOrDiscard()
    }

    /// Whether a brand-new thought is still a blank draft: no body text and no user-entered custom title.
    /// The rule lives in a pure model helper (`Thought.isBlankDraft`) so it is unit-tested, not trapped in
    /// view state (the spec 0009 `resolveTitleEdit` precedent). A title-only new thought counts as content
    /// (kept, not discarded): a user who dismisses the body editor and types only a title still has
    /// their thought saved. That path is reachable because the title stays tappable once `!isEditing`.
    private var isEmptyNewThought: Bool {
        Thought.isBlankDraft(
            paragraphs: paragraphs,
            hasCustomTitle: hasCustomTitle,
            customTitle: customTitleText
        )
    }
}

#Preview {
    NavigationStack {
        ThoughtDetailView(thought: MockThoughts.all[0], resolver: StoreAudioURLResolver(store: ThoughtStore()))
    }
}
