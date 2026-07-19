import SwiftUI

/// Detail for a single thought: its paragraphs and timestamp, themed. When the thought carries a recording
/// (spec 0007), a "Play recording" button starts it in the shared bottom PLAYER (spec 0027) - the thought
/// screen no longer hosts its own transport; play/pause, scrub, and skip live in the bottom player. The
/// text is editable with the keyboard, and a Resume action reopens the thought into a recording session to
/// keep dictating (feedback 0008).
struct ThoughtDetailView: View {
    let thought: Thought
    /// The ONE shared playback controller (spec 0027): the "Play recording" button starts this thought on
    /// it, surfacing the bottom player. Observed so the button reflects whether THIS thought is the loaded
    /// one. A bare/preview call site with no shared controller gets a private one (init fallback).
    @ObservedObject private var playbackController: ThoughtPlaybackController
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
    /// Route a bottom-player title tap to the thought it names (feedback 0027): the shared player now lives on
    /// the thought page too, and tapping its title opens that thought. Usually the thought already shown (a
    /// harmless re-open); when a folder queue has advanced to a DIFFERENT recording, this opens that one. The
    /// compact stack pushes it, the split detail selects it. Defaults to a no-op for a bare/preview call site.
    private let onOpenThought: (Thought) -> Void
    /// Whether this detail screen hosts the shared bottom PLAYER in its own bottom inset (feedback 0027). The
    /// real call site derives this from `StreamContainer.detailHostsBottomPlayer` (the ONE container decision):
    /// true on the compact (phone) stack, where the pushed detail owns its bottom inset so the player must be
    /// repeated here; false in the iPad split view, where the player is LIFTED above all columns
    /// (`StreamListView.liftedBottomStack`) - hosting it here too would double-render it. Defaults to true so a
    /// bare/preview call site (compact-like) still shows it.
    private let showsBottomPlayer: Bool
    /// Whether the bottom-bar search field performs IN-THOUGHT find on this detail screen (spec 0025,
    /// superseding spec 0021's "detail search routes to global results"): the field finds within THIS
    /// thought - seek + highlight + skip - rather than routing to the list. False at bare/preview call
    /// sites and in the split detail column (which defers search to the always-visible lifted GLOBAL bar,
    /// spec 0022), where the field is omitted so there are never two competing search surfaces.
    private let enablesFind: Bool
    /// Whether the resume icon applies for this thought per the audio-retention setting (spec 0021):
    /// resuming an existing recording always applies; recording onto a text-only thought applies only when
    /// the retention policy records audio. Computed by the composition root and passed in so the pure
    /// decision is not re-derived in the view. When false, the bottom bar omits the resume icon.
    private let resumeApplies: Bool
    /// The search query to carry into the in-note find when this thought is opened FROM an active search
    /// (feedback 0030, item 9): the composition root threads the live global query through the navigation so
    /// the detail auto-activates find with it, seeking and highlighting the FIRST hit exactly as if the user
    /// had typed it into the in-note field. Empty when the thought is opened NOT from a search (the normal
    /// case), where it does nothing. Applied ONCE on appear (a real find only where `enablesFind` is on), so
    /// the user's own later edits to the query are never re-seeded.
    private let initialFindQuery: String
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

    /// The live query typed into the bottom bar's search field for IN-THOUGHT find (spec 0025). A non-empty
    /// query drives `findNavigator` over this thought's title + paragraphs: every match is highlighted, the
    /// current one is scrolled into view, and the prev/next/count affordance shows. Clearing it removes the
    /// highlights and the affordance. Kept LOCAL so find state resets when the thought is left (the whole
    /// view is torn down) and so the field is inert on a bare/preview call site.
    @State private var findQuery = ""
    /// The navigator over the current find matches (spec 0025): its `currentIndex` drives the emphasized
    /// match and the scroll target, and prev/next step through the matches (wrapping). Rebuilt whenever the
    /// query or the thought's text changes so the highlights and count stay in sync.
    @State private var findNavigator = ThoughtFindNavigator(matches: [])

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
        onOpenThought: @escaping (Thought) -> Void = { _ in },
        showsBottomPlayer: Bool = true,
        enablesFind: Bool = false,
        resumeApplies: Bool = true,
        initialFindQuery: String = "",
        startInEdit: Bool = false
    ) {
        self.thought = thought
        self.onNewThought = onNewThought
        self.onOpenSettings = onOpenSettings
        self.onResume = onResume
        self.onCommitEdit = onCommitEdit
        self.onDiscardEmpty = onDiscardEmpty
        self.onDelete = onDelete
        self.onOpenThought = onOpenThought
        self.showsBottomPlayer = showsBottomPlayer
        self.enablesFind = enablesFind
        self.resumeApplies = resumeApplies
        self.initialFindQuery = initialFindQuery
        _paragraphs = State(initialValue: thought.paragraphs)
        _hasCustomTitle = State(initialValue: thought.hasCustomTitle)
        _customTitleText = State(initialValue: thought.title)
        // A brand-new thought (spec 0013) opens straight into the body editor and is unsaved until the
        // first non-empty commit. `startInEdit` drives both: the editor opens focused, and the thought is
        // tracked as unsaved so backing out untouched discards it.
        _isEditing = State(initialValue: startInEdit)
        _draft = State(initialValue: startInEdit ? thought.paragraphs.joined(separator: "\n\n") : "")
        _isUnsavedNewThought = State(initialValue: startInEdit)
        // Observe the ONE shared playback controller so the "Play recording" button starts this thought in
        // the bottom player (spec 0027). A bare/preview call site with no shared controller falls back to a
        // private one over the given resolver, so the button is inert but the view still builds.
        playbackController = controller ?? ThoughtPlaybackController(resolver: resolver, player: player)
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

            // `ScrollViewReader` lets the in-thought find SEEK the current match into view (spec 0025): the
            // title and each paragraph carry a stable `ThoughtFind.Region.scrollID` anchor, and a change to
            // the current match scrolls to its region's anchor.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: CanopySpacing.x4) {
                        titleHeader

                        // The metadata line is shared with the list card via `ThoughtMetaStats`: the duration
                        // now uses the SAME timer glyph and tight `x1` spacing as the card instead of a dash
                        // separator (feedback 0015), so the detail header and the card present it identically.
                        ThoughtMetaStats(thought: currentThought)
                            .font(.system(size: CanopyFont.sizeXs))
                            .foregroundStyle(CanopyColor.textSubtle)

                        // The "Play recording" affordance is NO LONGER inline in the note body (feedback 0030,
                        // item 5): it moved to the bottom stack (`detailBottomStack`), anchored at the bottom
                        // and floating with the find/search bar, consistent with the list screens. Starting
                        // playback there surfaces the shared `BottomPlayer` transport in the same bottom inset.

                        if isEditing {
                            TextEditor(text: $draft)
                                .focused($editorFocused)
                                .font(.system(size: CanopyFont.sizeBase))
                                .foregroundStyle(CanopyColor.text)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 240)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            bodyParagraphs
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
                // Seek the current match into view whenever it changes (a new query, next/previous, or a
                // query refinement that moves the first hit to a DIFFERENT region while the index stays 0).
                // Keyed on `currentMatch` (Equatable: region + range), NOT `currentIndex`: `refreshFind`
                // rebuilds the navigator to index 0 on every keystroke, so an index-keyed observer would miss
                // a same-index-different-region change and never re-seek. A `Match?` that stays nil (no
                // matches) does not fire, so there is no scroll when there is nothing to find. Scrolling to
                // the region's anchor is the only UI side effect, so it is device-verifiable while the pure
                // navigation state is unit-tested.
                .onChange(of: findNavigator.currentMatch) { _, _ in
                    scrollToCurrentMatch(using: proxy)
                }
            }
        }
        // Recompute the find matches whenever the query or the thought's text changes (spec 0025), so the
        // highlights and the "N of M" count stay in sync. The recompute is gated: find is inert where the
        // field is not shown (a bare/preview call site or the split detail column) and while editing (find
        // and edit are mutually exclusive), so a stale query cannot highlight under the editor.
        .onChange(of: findQuery) { _, _ in refreshFind() }
        .onChange(of: paragraphs) { _, _ in refreshFind() }
        // The transient "Copied to clipboard" confirmation (spec 0017), from the shared, lifecycle-tied
        // modifier so a rapid double-copy re-arms it and navigation cancels its timer. Pinned near the
        // bottom so it clears the thought text and the toolbar.
        .copiedConfirmation(trigger: copiedTrigger, isShown: $showCopiedConfirmation, alignment: .bottom)
        // The persistent bottom bar: a wide search field on the left driving IN-THOUGHT find (spec 0025,
        // superseding spec 0021's global routing) - seek + highlight + skip within THIS thought - plus the
        // find prev/next/count and the resume icon on the right. Which affordances show - and whether the bar
        // shows at all - is the pure, tested `ThoughtDetailBottomBar` decision: it is HIDDEN entirely while
        // editing the title or body (find and edit are mutually exclusive), so the field never renders under
        // the keyboard and a brand-new thought does not present two competing text fields. The bar reuses the
        // SAME component the list uses (not a fork).
        .safeAreaInset(edge: .bottom) {
            detailBottomStack
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
                // The gear (Settings) is the RIGHTMOST trailing item (feedback 0030, item 6), matching the
                // list / folder toolbars where it sits in the right-most position. `.topBarTrailing` items
                // lay out left-to-right in declaration order, so declaring it LAST (after the "..." menu)
                // puts it on the far right, consistent with `TopLevelFoldersView` / `FolderThoughtsView`.
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
        // A brand-new thought (spec 0013) opens with the body editor focused so the user can type at once.
        // Focus is set here (not in init) because a FocusState only takes effect once the view exists.
        // Opening a thought FROM an active search (feedback 0030, item 9) carries the global query in: seed
        // the in-note find with it ONCE on appear, which drives `refreshFind` (rebuilding the navigator to the
        // FIRST match) and, via the `currentMatch` observer, scrolls that hit into view - exactly as if the
        // user had typed the query into the in-note field. Gated on `enablesFind` (a real find surface, not the
        // split detail column or a preview) and a non-empty carried query; skipped for a brand-new thought,
        // which opens straight into the editor where find is inert.
        .onAppear {
            if isUnsavedNewThought {
                editorFocused = true
            } else if enablesFind, findQuery.isEmpty, !initialFindQuery.isEmpty {
                findQuery = initialFindQuery
            }
        }
        // Playback is NOT stopped on leaving the detail (spec 0027): it lives in the persistent bottom
        // player, so navigating away keeps the recording playing there (like any music app). Only finalize
        // a brand-new thought the user backed out of WITHOUT tapping Done (spec 0013): keep it if anything
        // was typed (auto-save, so typed content is never lost on back), discard it only if still blank. A
        // committed thought has cleared `isUnsavedNewThought` already.
        .onDisappear {
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
            // The title is a find region (spec 0025): its matches are highlighted like the body, with the
            // current match emphasized more strongly. The anchor lets `ScrollViewReader` seek a title match.
            Text(highlighted(currentThought.title, region: .title))
                .font(.system(size: CanopyFont.sizeXl, weight: .bold))
                .foregroundStyle(CanopyColor.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .id(ThoughtFind.Region.title.scrollID)
                // Title and body editing are MUTUALLY EXCLUSIVE (engineer review): entering title
                // edit while the body editor is open would commit via `currentThought` (built from
                // `paragraphs`, not the in-flight `draft`) and drop freshly typed body text. So the
                // title is only tappable when not already editing the body; Done exits one first.
                .onTapGesture { if onCommitEdit != nil, !isEditing { beginEditTitle() } }
                .accessibilityAddTraits(onCommitEdit != nil && !isEditing ? .isButton : [])
                .accessibilityHint(onCommitEdit != nil && !isEditing ? "Double tap to edit the title" : "")
        }
    }

    /// The read-mode thought body: each paragraph rendered with the in-thought find highlights (spec 0025)
    /// and a stable scroll anchor so the current match can be sought into view. Tapping the body begins
    /// editing (feedback 0010), which is mutually exclusive with find - entering the editor clears the find
    /// (see `beginEdit`). Only tappable where the call site can persist the result (`onCommitEdit`).
    private var bodyParagraphs: some View {
        VStack(alignment: .leading, spacing: CanopySpacing.x4) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                Text(highlighted(paragraph, region: .paragraph(index)))
                    .font(.system(size: CanopyFont.sizeBase))
                    .foregroundStyle(CanopyColor.text)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(ThoughtFind.Region.paragraph(index).scrollID)
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

    /// The pure decision for what the thought-detail bottom bar shows (spec 0021), extracted into the tested
    /// `ThoughtDetailBottomBar` seam so the "hidden while editing / search / resume" logic is not re-derived
    /// inline. The `.safeAreaInset` gate and the `bottomBar` body both read from this one decision.
    private var bottomBarLayout: ThoughtDetailBottomBar {
        ThoughtDetailBottomBar.decide(
            canSearch: enablesFind,
            canResume: onResume != nil,
            resumeApplies: resumeApplies,
            isEditing: isEditingAnything,
            isUnsavedNewThought: isUnsavedNewThought
        )
    }

    /// The thought page's bottom safe-area inset (feedback 0027): the SHARED bottom PLAYER above the thought's
    /// own bottom bar, in the same order the list screens' `StreamBottomStack` uses (player above the bar).
    /// This anchors the ONE shared player on the thought page so playing a recording surfaces the same
    /// transport - play/pause, scrubber, +/-15s - that the list screens show, driven by the same
    /// `playbackController`. The player renders itself only while a recording is loaded (it collapses to
    /// nothing otherwise), and it is independent of the bar's editing gate - so it stays visible while the
    /// thought text is being edited, exactly as it does on the list screens. On the iPad split view this inset
    /// is empty for the detail column (the player is lifted above all columns), so the player never
    /// double-renders there; on compact this IS the player's home while a thought is open.
    ///
    /// Unlike the list's `StreamBottomStack` (which also gates its player on `screenState != .emptyStore`),
    /// the detail player is gated ONLY on `showsBottomPlayer` (architect review): the empty-store gate is
    /// deliberately omitted here because a thought detail is never the empty-store screen, so the two
    /// predicates are intentionally not coupled - do not re-add the store-state gate to this call site.
    ///
    /// The "Play recording" affordance ALSO lives here now (feedback 0030, item 5), anchored at the bottom
    /// and floating with the find/search bar instead of inline under the title: shown ABOVE the bar for an
    /// audio thought that is NOT yet the loaded one, it starts this thought on the shared controller, which
    /// surfaces the full `BottomPlayer` transport (play/pause, scrubber, +/-15s) in this same inset. Once
    /// loaded, `BottomPlayer` renders and the start affordance drops away, so the two never both show. A
    /// text-only thought has no audio, so no play affordance appears. Gated on `showsBottomPlayer` like the
    /// player, so the split detail column (player lifted above all columns) shows neither.
    private var detailBottomStack: some View {
        VStack(spacing: CanopySpacing.x3) {
            if showsBottomPlayer {
                if thought.hasAudio, !isThisThoughtLoaded {
                    playButton
                }
                BottomPlayer(controller: playbackController, onOpenThought: { onOpenThought($0) })
            }
            if bottomBarLayout.isVisible {
                bottomBar
            }
        }
        .padding(.bottom, CanopySpacing.x2)
    }

    /// The persistent bottom bar for the thought page: the SAME `BottomBar` component the list uses, its
    /// search field now driving IN-THOUGHT find (spec 0025, superseding spec 0021's global routing). What it
    /// shows is the pure `bottomBarLayout` decision (the find field when the call site enables it; the resume
    /// icon when a session can be reopened; hidden entirely while editing). The trailing slot carries the
    /// find prev/next chevrons + "N of M" count WHILE a find is active, then the resume icon. Highlights and
    /// the count update live as the query changes (via `refreshFind`, keyed on `findQuery`), so there is no
    /// submit step - each keystroke re-finds within this thought.
    private var bottomBar: some View {
        let layout = bottomBarLayout
        return BottomBar(
            query: $findQuery,
            showsSearchField: layout.showsSearch
        ) {
            if findNavigator.hasMatches {
                findNavigationControls
            }
            if layout.showsResume {
                BottomBarRecordButton(accessibilityLabel: resumeAccessibilityLabel) {
                    onResume?(currentThought)
                }
            }
        }
    }

    /// The in-thought find "N of M" count and the prev/next chevrons, shown beside the search field while a
    /// find has matches (spec 0025). The whole group sits on a solid Canopy surface pill (feedback 0030, item
    /// 10, via the shared `BottomBarButtonGroup`): the count previously floated over the content with no
    /// background and was hard to read, so it now reads as part of the find-bar GROUP with the bar's own
    /// surface + border + capsule treatment, matching the search field's pill beside it. Prev/next step
    /// through the matches (wrapping); the count is the pure `ThoughtFindNavigator.countLabel`. Clearing the
    /// query hides this whole affordance (no matches).
    private var findNavigationControls: some View {
        BottomBarButtonGroup {
            Text(findNavigator.countLabel)
                .font(.system(size: CanopyFont.sizeXs, weight: .semibold))
                .foregroundStyle(CanopyColor.text)
                .monospacedDigit()
                .padding(.leading, CanopySpacing.x1)
                .accessibilityLabel("Match \(findNavigator.countLabel)")
            Button {
                findNavigator.previous()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: CanopyFont.sizeSm, weight: .semibold))
                    .foregroundStyle(CanopyColor.primary)
                    .frame(width: CanopySpacing.x6, height: CanopySpacing.x8)
            }
            .accessibilityLabel("Previous match")
            Button {
                findNavigator.next()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: CanopyFont.sizeSm, weight: .semibold))
                    .foregroundStyle(CanopyColor.primary)
                    .frame(width: CanopySpacing.x6, height: CanopySpacing.x8)
            }
            .accessibilityLabel("Next match")
        }
    }

    /// The resume icon's accessibility label (the text label is dropped in the bottom bar, spec 0021):
    /// "Resume recording" for a thought that already carries audio, else "Record audio for this thought".
    private var resumeAccessibilityLabel: String {
        currentThought.hasAudio ? "Resume recording" : "Record audio for this thought"
    }

    /// Whether this thought's recording is the one currently loaded in the shared controller. Gates whether
    /// the bottom-anchored "Play recording" affordance shows (feedback 0030, item 5): while this thought is
    /// loaded, `BottomPlayer` renders the full transport instead, so the start affordance drops away and the
    /// detail never competes with the player for control.
    private var isThisThoughtLoaded: Bool { playbackController.isLoaded(thought) }

    /// The bottom-anchored "Play recording" affordance (spec 0027, moved to the bottom stack in feedback
    /// 0030): tapping it starts this thought's recording on the shared controller, which surfaces the full
    /// `BottomPlayer` transport - play/pause, scrubber, +/-15s - in the SAME bottom inset. It is NOT a
    /// transport itself; it only STARTS playback. It floats with the find/search bar at the bottom of the
    /// thought page, consistent with the list screens, and is shown only for an audio thought that is not yet
    /// the loaded one (see `detailBottomStack`), so it never overlaps the player.
    private var playButton: some View {
        Button {
            playbackController.play(thought: thought)
        } label: {
            HStack(spacing: CanopySpacing.x2) {
                Image(systemName: "play.fill")
                Text("Play recording")
                    .font(.system(size: CanopyFont.sizeSm, weight: .semibold))
            }
            .foregroundStyle(CanopyColor.primaryForeground)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, CanopySpacing.x4)
            .padding(.vertical, CanopySpacing.x3)
            .background(CanopyColor.primary)
            .clipShape(Capsule())
            .shadow(color: CanopyColor.overlay.opacity(0.25), radius: 12, y: 6)
        }
        .padding(.horizontal, CanopySpacing.x4)
        .accessibilityLabel("Play recording")
    }

    private func beginEdit() {
        // Find and edit are mutually exclusive (spec 0025): clear any in-flight find so no highlights or
        // find bar survive into the editor.
        clearFind()
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
        // Find and edit are mutually exclusive (spec 0025): clear any in-flight find first.
        clearFind()
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

    // MARK: - In-thought find (spec 0025)

    /// Recompute the find matches over the current title + paragraphs and rebuild the navigator (spec 0025).
    /// Find is INERT while editing (find and edit are mutually exclusive) - `beginEdit`/`beginEditTitle`
    /// clear the query, so a rebuild during an edit yields no matches - and where the field is not shown
    /// (a bare/preview call site or the split detail column, `!enablesFind`). Rebuilding the navigator resets
    /// the current match to the first, so a changed query seeks to the first hit.
    private func refreshFind() {
        guard enablesFind, !isEditingAnything else {
            findNavigator = ThoughtFindNavigator(matches: [])
            return
        }
        let matches = ThoughtFind.matches(
            title: currentThought.title,
            paragraphs: paragraphs,
            query: findQuery
        )
        findNavigator = ThoughtFindNavigator(matches: matches)
    }

    /// Clear the in-thought find: empty the query and drop all matches, so highlights and the
    /// prev/next/count affordance disappear (spec 0025). Called when entering an editor (mutually exclusive
    /// with find) - the `findQuery` change also fires `refreshFind`, which is a harmless no-op then.
    private func clearFind() {
        findQuery = ""
        findNavigator = ThoughtFindNavigator(matches: [])
    }

    /// Build a highlighted `AttributedString` for one find region's text (spec 0025): every match gets a
    /// Canopy highlight background, and the CURRENT match is emphasized more strongly (a stronger background
    /// plus bold) so the user can tell which one the prev/next controls point at. When no find is active the
    /// text is returned plain. `region` selects which matches (title vs. a paragraph) apply to this string.
    private func highlighted(_ text: String, region: ThoughtFind.Region) -> AttributedString {
        var attributed = AttributedString(text)
        guard findNavigator.hasMatches else { return attributed }
        let current = findNavigator.currentMatch
        for match in findNavigator.matches where match.region == region {
            // The match carries CHARACTER OFFSETS (instance-independent, unlike a `String.Index` which is
            // valid only against its producing string - the title is re-derived each render, engineer
            // review). Map them into the `AttributedString` (built from this same region text, so the
            // character offsets align). Guard the bounds so a stale match against a just-edited paragraph is
            // skipped rather than crashing.
            let lower = match.characterRange.lowerBound
            let upper = match.characterRange.upperBound
            guard lower >= 0, upper <= attributed.characters.count, lower < upper else { continue }
            let start = attributed.index(attributed.startIndex, offsetByCharacters: lower)
            let end = attributed.index(attributed.startIndex, offsetByCharacters: upper)
            let range = start..<end
            let isCurrent = match == current
            attributed[range].backgroundColor = isCurrent ? CanopyColor.warning : CanopyColor.warning.opacity(0.35)
            if isCurrent {
                attributed[range].foregroundColor = CanopyColor.warningForeground
                attributed[range].font = .system(size: fontSize(for: region), weight: .bold)
            }
        }
        return attributed
    }

    /// The base font size for a region, so a bold CURRENT-match run keeps the region's own size (the title is
    /// larger than a body paragraph). Reuses the same Canopy sizes the plain text uses.
    private func fontSize(for region: ThoughtFind.Region) -> CGFloat {
        switch region {
        case .title:
            return CanopyFont.sizeXl
        case .paragraph:
            return CanopyFont.sizeBase
        }
    }

    /// Scroll the current find match's region into view (spec 0025): the only UI side effect of the pure
    /// navigation state. Anchored on the region's stable `scrollID`, animated so a next/previous glides. A
    /// no-op when there is no current match (an empty query or no hits).
    private func scrollToCurrentMatch(using proxy: ScrollViewProxy) {
        guard let region = findNavigator.currentMatch?.region else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(region.scrollID, anchor: .center)
        }
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
