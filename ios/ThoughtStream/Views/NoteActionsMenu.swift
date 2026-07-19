import SwiftUI
import UIKit

/// The Share + Copy actions for a note (spec 0017), factored into ONE place so the note detail
/// toolbar menu and the list-row context menu never drift and the queued Delete addition (spec 0020)
/// is a single change. Callers embed these as the leading items of a `Menu` / `.contextMenu` and may
/// append their own trailing items (Move, Delete) after them via `extraContent`.
///
/// Share sends `note.shareableText` through the system share sheet (`ShareLink`); Copy text puts the
/// same string on the pasteboard through `NoteClipboard.copy` and calls `onCopied` so the caller can
/// flash its confirmation. Keeping both on `note.shareableText` is what makes share and copy identical.
struct NoteActionsMenu<Extra: View>: View {
    let note: Note
    /// Called after Copy text places the note on the pasteboard, so the caller flashes its transient
    /// "Copied to clipboard" confirmation (`CopiedConfirmation`).
    let onCopied: () -> Void
    /// Extra menu items the caller appends after Share / Copy (e.g. Move, and Delete in spec 0020).
    @ViewBuilder let extraContent: Extra

    init(note: Note, onCopied: @escaping () -> Void, @ViewBuilder extraContent: () -> Extra) {
        self.note = note
        self.onCopied = onCopied
        self.extraContent = extraContent()
    }

    var body: some View {
        ShareLink(item: note.shareableText) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        Button {
            NoteClipboard.copy(note)
            onCopied()
        } label: {
            Label("Copy text", systemImage: "doc.on.doc")
        }
        extraContent
    }
}

extension NoteActionsMenu where Extra == EmptyView {
    /// Share + Copy with no extra items.
    init(note: Note, onCopied: @escaping () -> Void) {
        self.init(note: note, onCopied: onCopied, extraContent: { EmptyView() })
    }
}

/// The one place a note's shareable text is written to the pasteboard, shared by every Copy-text site
/// (spec 0017) so they all copy exactly `note.shareableText`.
enum NoteClipboard {
    static func copy(_ note: Note) {
        UIPasteboard.general.string = note.shareableText
    }
}

/// The transient "Copied to clipboard" confirmation chip (spec 0017), shared by the note detail page
/// and the list so both look identical (muted-capsule styling, matching the dictation command chips).
/// It is shown via the `copiedConfirmation` modifier below, whose auto-dismiss is lifecycle-tied.
struct CopiedConfirmation: View {
    var body: some View {
        HStack(spacing: CanopySpacing.x2) {
            Image(systemName: "doc.on.doc")
            Text("Copied to clipboard")
                .font(.system(size: CanopyFont.sizeSm, weight: .semibold))
        }
        .foregroundStyle(CanopyColor.mutedForeground)
        .padding(.horizontal, CanopySpacing.x4)
        .padding(.vertical, CanopySpacing.x2)
        .background(CanopyColor.muted)
        .clipShape(Capsule())
        .shadow(color: CanopyColor.overlay.opacity(0.2), radius: 8, y: 4)
        .accessibilityLabel("Copied to clipboard")
    }
}

/// A monotonic token bumped on each Copy so the confirmation's auto-hide is lifecycle-tied rather than
/// a detached timer (architect / engineer review): the `.task(id:)` restarts on every bump, so a rapid
/// second copy re-arms the timer (never hiding the chip early), and the task is cancelled on navigation
/// away so a fired timer never mutates a gone view. Callers bump `trigger` from their copy handler.
private struct CopiedConfirmationModifier: ViewModifier {
    /// Bumped by the caller on each copy; the chip shows while non-zero and re-arms its hide timer on
    /// every change.
    let trigger: Int
    @Binding var isShown: Bool
    /// Where the chip sits over the caller's content.
    let alignment: Alignment

    func body(content: Content) -> some View {
        content
            .overlay(alignment: alignment) {
                if isShown {
                    CopiedConfirmation()
                        .padding(.top, alignment == .top ? CanopySpacing.x2 : 0)
                        .padding(.bottom, alignment == .bottom ? CanopySpacing.x8 : 0)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isShown)
            // Keyed on `trigger`: a fresh copy cancels any in-flight hide and starts a new delay, so a
            // double-copy keeps the chip up the full duration. Cancellation on view teardown stops a
            // stale timer from clearing state after navigation.
            .task(id: trigger) {
                guard trigger > 0 else { return }
                isShown = true
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                guard !Task.isCancelled else { return }
                isShown = false
            }
    }
}

extension View {
    /// Show the shared "Copied to clipboard" confirmation over this view, auto-hiding after a moment
    /// (spec 0017). `trigger` is a counter the caller bumps on each copy; `isShown` holds the chip's
    /// current visibility. The auto-hide is tied to this view's lifecycle (see `CopiedConfirmationModifier`).
    func copiedConfirmation(trigger: Int, isShown: Binding<Bool>, alignment: Alignment) -> some View {
        modifier(CopiedConfirmationModifier(trigger: trigger, isShown: isShown, alignment: alignment))
    }
}

/// The transient "Note deleted - Undo" affordance (spec 0020): a muted capsule matching the copied chip,
/// with an Undo button that calls back the same restore path shake-to-undo uses. Shown after any delete
/// (list swipe, list/detail menu) for a few seconds so undo is discoverable without shaking.
struct UndoDeleteAffordance: View {
    /// Called when the user taps Undo. Restores the note (see `NoteDeletionController.undo`).
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: CanopySpacing.x3) {
            Image(systemName: "trash")
            Text("Note deleted")
                .font(.system(size: CanopyFont.sizeSm, weight: .semibold))
            Button(action: onUndo) {
                Text("Undo")
                    .font(.system(size: CanopyFont.sizeSm, weight: .bold))
                    .foregroundStyle(CanopyColor.primary)
            }
            .accessibilityLabel("Undo delete")
        }
        .foregroundStyle(CanopyColor.mutedForeground)
        .padding(.horizontal, CanopySpacing.x4)
        .padding(.vertical, CanopySpacing.x2)
        .background(CanopyColor.muted)
        .clipShape(Capsule())
        .shadow(color: CanopyColor.overlay.opacity(0.2), radius: 8, y: 4)
    }
}

/// The lifecycle-tied host for the "Note deleted - Undo" affordance (spec 0020), the same shape as the
/// copied-confirmation modifier so its auto-hide re-arms on a rapid second delete and cancels on view
/// teardown - never a detached `asyncAfter`. When the window (~5s) elapses WITHOUT an undo, it calls
/// `onExpire` so the caller commits the delete (purges the trashed files). An undo clears `pending`,
/// which restarts the `.task(id:)` and skips the expire.
private struct UndoDeleteAffordanceModifier: ViewModifier {
    /// Bumped by the caller on each delete; the affordance shows while a delete is pending and re-arms
    /// its window on every change so a second delete never fires the first delete's purge early.
    let trigger: Int
    /// Whether a delete is currently pending an undo window. The affordance shows while true.
    let isPending: Bool
    let alignment: Alignment
    /// Tapped Undo -> restore.
    let onUndo: () -> Void
    /// The window elapsed with no undo -> commit (purge).
    let onExpire: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: alignment) {
                if isPending {
                    UndoDeleteAffordance(onUndo: onUndo)
                        .padding(.top, alignment == .top ? CanopySpacing.x2 : 0)
                        .padding(.bottom, alignment == .bottom ? CanopySpacing.x8 : 0)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isPending)
            // Keyed on `trigger`: each delete re-arms a fresh ~5s window; a second delete cancels the
            // first's window (whose caller already committed the first). Cancellation on teardown stops a
            // stale timer from purging after navigation. The expire only fires when still pending, so an
            // undo (which clears pending) races cleanly - the reordered task sees `isPending == false`.
            .task(id: trigger) {
                guard trigger > 0, isPending else { return }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                onExpire()
            }
    }
}

extension View {
    /// Show the shared "Note deleted - Undo" affordance over this view (spec 0020), auto-committing the
    /// delete after ~5s if the user does not undo. `trigger` is bumped on each delete; `isPending` holds
    /// whether an undo window is open. The window is tied to this view's lifecycle (see the modifier).
    func undoDeleteAffordance(
        trigger: Int,
        isPending: Bool,
        alignment: Alignment,
        onUndo: @escaping () -> Void,
        onExpire: @escaping () -> Void
    ) -> some View {
        modifier(UndoDeleteAffordanceModifier(
            trigger: trigger, isPending: isPending, alignment: alignment,
            onUndo: onUndo, onExpire: onExpire))
    }
}
