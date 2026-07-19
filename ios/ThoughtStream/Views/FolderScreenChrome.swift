import SwiftUI

/// Shared chrome for the redesigned folder screens (spec 0026): the tighter row insets, the "no matches"
/// search state, and the advisory folder-name banner. Factored here so the top-level folders screen and the
/// folder thoughts screen render them identically (these were private helpers on the retired interleaving
/// `FolderContentsView`).

/// The ONE thought row for a flat thought list AND a global search-result list (spec 0026, architect
/// review): tapping opens the thought, and the row carries the full affordances - a leading swipe to Play
/// (only a recorded thought) or Move, a trailing swipe to Delete, and a long-press context menu (Share /
/// Copy via `ThoughtActionsMenu`, plus Move and Delete). Both `FolderThoughtsView` and
/// `TopLevelFoldersView`'s search-results list render THIS, so an identical thought looks and behaves the
/// same everywhere - a search result cannot gain or lose swipe-to-play based only on which screen the search
/// started from. This is also the single wiring point a future "play -> bottom player from a row" hooks into.
struct ThoughtResultRow: View {
    let thought: Thought
    /// The shared playback controller; nil (preview / bare call site) omits the swipe-to-play action.
    let playbackController: ThoughtPlaybackController?
    let onOpen: (Thought) -> Void
    let onMove: (Thought) -> Void
    let onDelete: (UUID) -> Void
    /// Bumped when a Copy fires, so the host can flash its shared "Copied to clipboard" confirmation.
    let onCopied: () -> Void

    var body: some View {
        // A plain-styled Button as an .insetGrouped List cell fights the list's own tap handling
        // (feedback 0025: taps needed multiple presses). A plain row + contentShape + onTapGesture is
        // the reliable list-cell tap; swipeActions/contextMenu still attach to the row. The isButton
        // trait keeps VoiceOver treating the row as a button.
        ThoughtCard(thought: thought)
            .contentShape(Rectangle())
            .onTapGesture { onOpen(thought) }
            .accessibilityAddTraits(.isButton)
            .unifiedRow()
        .contextMenu {
            ThoughtActionsMenu(thought: thought, onCopied: onCopied) {
                Button {
                    onMove(thought)
                } label: {
                    Label("Move to folder", systemImage: "folder")
                }
                Button(role: .destructive) {
                    onDelete(thought.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if thought.hasAudio, let controller = playbackController {
                Button {
                    controller.play(thought: thought)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .tint(CanopyColor.success)
            }
            Button {
                onMove(thought)
            } label: {
                Label("Move", systemImage: "folder")
            }
            .tint(CanopyColor.primary)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDelete(thought.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

extension View {
    /// A row inside the UNIFIED, Notes-app-style grouped list (feedback 0025). The per-row surface / border /
    /// rounded-corner CHROME moved off the individual rows and onto the whole list container: rows now sit on
    /// the shared `surface` fill and are separated by hairline dividers in the Canopy `border` color, so the
    /// list reads as ONE inset card rather than a stack of free-floating cards.
    ///
    /// The row content supplies its own internal padding (the card views' `x4`), so the row insets here are
    /// zeroed on the leading/trailing edge (`x4` is baked into the content) and the vertical inset is dropped
    /// to `x0` - the compact rhythm now comes from the content padding + dividers, not from gaps between
    /// cards. The separator is inset to line up with the content, matching the Notes app.
    func unifiedRow() -> some View {
        self
            .listRowInsets(EdgeInsets(
                top: CanopySpacing.x0,
                leading: CanopySpacing.x0,
                bottom: CanopySpacing.x0,
                trailing: CanopySpacing.x0
            ))
            .listRowBackground(CanopyColor.surface)
            .listRowSeparatorTint(CanopyColor.border)
            .alignmentGuide(.listRowSeparatorLeading) { _ in CanopySpacing.x4 }
    }
}

extension View {
    /// The single container styling for a UNIFIED, Notes-app-style grouped list (feedback 0025): the inset
    /// rounded card that wraps ALL the rows as one surface, so the border and background belong to the WHOLE
    /// list rather than each row. `.insetGrouped` supplies the inset rounded container + hairline dividers;
    /// `scrollContentBackground(.hidden)` drops the system grouped backdrop so the screen's Canopy `bg` shows
    /// through around the card. Used identically by both list screens and the search results so the grouping
    /// is single-sourced.
    func unifiedList() -> some View {
        self
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            // Tighten the large default top margin `.insetGrouped` reserves above the first row
            // (feedback 0026, item 1) so the scrolling title header sits close to the toolbar rather than
            // floating with a wide gap, matching the Notes app. Only the TOP margin is overridden; the
            // side/bottom grouped margins stay so the inset card keeps its shape.
            .contentMargins(.top, CanopySpacing.x2, for: .scrollContent)
    }
}

/// Shown when a search is active but matched nothing in a non-empty store (spec 0021). The search field
/// stays visible (it lives in the bottom bar), so the user can edit or clear the query.
struct NoSearchMatchesState: View {
    let query: String

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: CanopySpacing.x3) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: CanopyFont.sizeX4xl, weight: .semibold))
                .foregroundStyle(CanopyColor.primary)
            Text("No matches")
                .font(.system(size: CanopyFont.sizeXl, weight: .semibold))
                .foregroundStyle(CanopyColor.text)
            Text("No thought's title or text contains \"\(trimmedQuery)\".")
                .font(.system(size: CanopyFont.sizeSm))
                .foregroundStyle(CanopyColor.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CanopySpacing.x8)
        }
    }
}

/// The single active folder dialog on the top-level folders screen (spec 0021 rename-bug fix, carried into
/// spec 0026). One enum drives all three dialogs from ONE state so they are not three stacked `.alert`s
/// racing each other; each is hosted on its own hidden anchor via a per-case binding. `Identifiable` for
/// stable presentation. In the redesign folder paths are one level, so a path is always `[name]`.
enum FolderDialog: Identifiable, Equatable {
    case newFolder
    case renameFolder(path: [String], currentName: String)
    case deleteFolder(path: [String])

    var id: String {
        switch self {
        case .newFolder: return "new"
        case let .renameFolder(path, _): return "rename:" + path.joined(separator: "/")
        case let .deleteFolder(path): return "delete:" + path.joined(separator: "/")
        }
    }

    var isNewFolder: Bool { if case .newFolder = self { return true }; return false }
    var isRenameFolder: Bool { if case .renameFolder = self { return true }; return false }
    var isDeleteFolder: Bool { if case .deleteFolder = self { return true }; return false }
}

/// The empty-state call to action (spec 0021, extended feedback 0026 item 6): when a list or folder has no
/// thoughts, show the actions in the middle of the screen. It offers up to THREE actions: MOVE thoughts into
/// this folder (only inside a user folder that could receive thoughts - `onMoveToFolder` non-nil), RECORD a
/// thought, and NEW keyboard thought. This is the ONE place these actions keep their text labels (the
/// persistent bottom bar drops them). The Move action is omitted where "move into this folder" is meaningless
/// (the root / All Thoughts / an alias, or a truly empty store with nothing to move).
struct FolderEmptyStateCTA: View {
    /// Whether this is the root list (vs a folder), only for the supporting copy.
    let isRoot: Bool
    /// Move existing thoughts INTO this folder (feedback 0026, item 6). Nil omits the action where moving
    /// into "this folder" makes no sense (root / alias) or there is nothing to move.
    var onMoveToFolder: (() -> Void)?
    let onRecord: () -> Void
    let onNewKeyboardThought: () -> Void

    var body: some View {
        VStack(spacing: CanopySpacing.x4) {
            Image(systemName: "waveform")
                .font(.system(size: CanopyFont.sizeX4xl, weight: .semibold))
                .foregroundStyle(CanopyColor.primary)
            Text(isRoot ? "No thoughts yet" : "This folder is empty")
                .font(.system(size: CanopyFont.sizeXl, weight: .semibold))
                .foregroundStyle(CanopyColor.text)
            Text("Tap Record and start talking, or make a thought with the keyboard.")
                .font(.system(size: CanopyFont.sizeSm))
                .foregroundStyle(CanopyColor.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CanopySpacing.x8)

            RecordButton(action: onRecord)
                .padding(.top, CanopySpacing.x2)
            Button(action: onNewKeyboardThought) {
                capsuleLabel(systemImage: "square.and.pencil", title: "New thought")
            }
            .accessibilityLabel("New thought")
            if let onMoveToFolder {
                Button(action: onMoveToFolder) {
                    capsuleLabel(systemImage: "folder", title: "Move thoughts here")
                }
                .accessibilityLabel("Move thoughts here")
            }
        }
    }

    /// A bordered-capsule secondary action label, shared by the New-thought and Move buttons.
    private func capsuleLabel(systemImage: String, title: String) -> some View {
        HStack(spacing: CanopySpacing.x2) {
            Image(systemName: systemImage)
            Text(title)
                .font(.system(size: CanopyFont.sizeBase, weight: .semibold))
        }
        .foregroundStyle(CanopyColor.primary)
        .padding(.horizontal, CanopySpacing.x6)
        .padding(.vertical, CanopySpacing.x3)
        .overlay(
            Capsule().stroke(CanopyColor.primary, lineWidth: 1)
        )
    }
}

/// A brief, non-blocking banner for a rejected/conflicting folder name, styled with Canopy warning tokens so
/// it reads as an advisory rather than a destructive error.
struct FolderErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: CanopySpacing.x2) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(message)
                .font(.system(size: CanopyFont.sizeSm, weight: .semibold))
        }
        .foregroundStyle(CanopyColor.warningForeground)
        .padding(.horizontal, CanopySpacing.x4)
        .padding(.vertical, CanopySpacing.x2)
        .background(CanopyColor.warning)
        .clipShape(Capsule())
        .shadow(color: CanopyColor.overlay.opacity(0.2), radius: 8, y: 4)
        .padding(.top, CanopySpacing.x2)
    }
}
