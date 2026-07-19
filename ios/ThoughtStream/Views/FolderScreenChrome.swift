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
        Button {
            onOpen(thought)
        } label: {
            ThoughtCard(thought: thought)
        }
        .buttonStyle(.plain)
        .tightRowInsets()
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
    /// The TIGHTER row insets for the redesigned dense list (spec 0026): the vertical inset drops from the
    /// old `x1_5` (6pt) to `x0_5` (2pt) so rows read as a compact list rather than bulky spaced cards, while
    /// the horizontal inset (`x4`) and each card's own internal padding are unchanged - so tap targets stay
    /// adequate and the metadata stays legible.
    func tightRowInsets() -> some View {
        self
            .listRowInsets(EdgeInsets(
                top: CanopySpacing.x0_5,
                leading: CanopySpacing.x4,
                bottom: CanopySpacing.x0_5,
                trailing: CanopySpacing.x4
            ))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
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

/// The empty-state call to action (spec 0021): when a list or folder has no thoughts anywhere, show the
/// RECORD button in the middle of the screen WITH its text label, and a NEW-THOUGHT button directly below
/// it. This is the ONE place record/new-thought keep their labels (the persistent bottom bar drops them).
struct FolderEmptyStateCTA: View {
    /// Whether this is the root list (vs a folder), only for the supporting copy.
    let isRoot: Bool
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
                HStack(spacing: CanopySpacing.x2) {
                    Image(systemName: "square.and.pencil")
                    Text("New thought")
                        .font(.system(size: CanopyFont.sizeBase, weight: .semibold))
                }
                .foregroundStyle(CanopyColor.primary)
                .padding(.horizontal, CanopySpacing.x6)
                .padding(.vertical, CanopySpacing.x3)
                .overlay(
                    Capsule().stroke(CanopyColor.primary, lineWidth: 1)
                )
            }
            .accessibilityLabel("New thought")
        }
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
