import SwiftUI

/// The composed bottom safe-area stack shared by the compact per-screen bar and the split view's lifted bar
/// (spec 0022): from top to bottom, the transient "Thought deleted - Undo" chip (spec 0020), the bottom
/// PLAYER (spec 0027, superseding spec 0015's simpler now-playing bar), then the persistent bottom bar with
/// the search field + record/new-thought actions (spec 0021), all in ONE inset so they stack cleanly via the
/// shared VStack spacing and reserve real layout space - no hardcoded overlay clearance, no overlap.
///
/// This was duplicated verbatim between `FolderContentsView.bottomStack` (compact) and
/// `StreamListView.liftedBottomStack` (split), INCLUDING the 5s undo-window timer, so a change to one could
/// drift from the other and the single-bottom-bar invariant was untested. Extracting ONE component de-dups
/// it, locks the invariant in one place, and gives the future Watch target (spec 0023) a reusable piece
/// instead of a third copy. The undo-window timer lives here (lifecycle-tied, keyed on the monotonic delete
/// trigger, the same shape as the copied-confirmation chip); the composition root still owns the UndoManager
/// wiring and the scene-phase commit.
struct StreamBottomStack: View {
    /// The shared live search query (two-way bound so the field drives the host's results).
    @Binding var query: String
    /// The resolved content state, so the stack hides its search field in a truly empty store (nothing to
    /// search) and omits the whole bar in `.emptyStore` (the centered CTA carries labeled actions there).
    let screenState: FolderScreenState
    /// The shared undoable-delete coordinator (spec 0020): its `pending` shows the undo chip, and its
    /// `deleteTrigger` keys the lifecycle-tied purge timer.
    @ObservedObject var deletion: ThoughtDeletionController
    /// The shared playback controller (spec 0027), so the bottom player shows while something plays.
    /// Optional so a preview / bare call site without shared playback simply omits the player.
    let playbackController: ThoughtPlaybackController?

    /// Open a thought (from a now-playing bar tap): the compact screen pushes it, the split view selects it
    /// in the detail column.
    let onOpenThought: (Thought) -> Void
    /// Create a blank keyboard thought (the new-thought icon), filed in the host's current folder context.
    let onNewKeyboardThought: () -> Void
    /// Start a new dictation session (the record button), filed in the host's current folder context.
    let onNewThought: () -> Void

    var body: some View {
        VStack(spacing: CanopySpacing.x3) {
            if deletion.pending != nil {
                UndoDeleteAffordance(onUndo: { Task { await deletion.undo() } })
                    .transition(.opacity)
            }
            // In a truly empty store the centered CTA already carries labeled Record + New-thought buttons
            // (spec 0021), so the bottom bar (which would only duplicate them, with no field to search) is
            // omitted; the undo chip above can still show while a just-deleted thought is pending.
            if screenState != .emptyStore {
                if let controller = playbackController {
                    BottomPlayer(controller: controller, onOpenThought: onOpenThought)
                }
                BottomBar(query: $query, showsSearchField: screenState.showsSearchField) {
                    // The new-thought + record pair sit behind ONE shared background (feedback 0023) so they
                    // read as a single grouped unit beside the search pill, matching the top-left new-folder +
                    // sort toolbar group. Each button keeps its own tap target, label, and affordance.
                    BottomBarButtonGroup {
                        BottomBarIconButton(
                            systemImage: "square.and.pencil",
                            accessibilityLabel: "New thought"
                        ) { onNewKeyboardThought() }
                        BottomBarRecordButton(accessibilityLabel: "Record") { onNewThought() }
                    }
                }
            }
        }
        .padding(.bottom, CanopySpacing.x2)
        .animation(.easeInOut(duration: 0.2), value: deletion.pending != nil)
        // The undo window's ~5s timer is lifecycle-tied to THIS view (spec 0020), the same shape as the
        // copied-confirmation chip: keyed on the monotonic delete trigger so a rapid second delete re-arms
        // it and teardown cancels it, never a detached timer. On expiry with a still-pending delete it
        // commits (purges). The composition root still owns the UndoManager + scene-phase commit.
        .task(id: deletion.deleteTrigger) {
            guard deletion.deleteTrigger > 0, deletion.pending != nil else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await deletion.commitWindow()
        }
    }
}
