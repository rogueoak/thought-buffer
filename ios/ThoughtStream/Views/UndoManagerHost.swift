import SwiftUI
import UIKit

/// A stable, first-responder-backed `UndoManager` for Shake to Undo (spec 0021 bug fix).
///
/// The system Shake to Undo gesture invokes the `undoManager` of the FIRST RESPONDER's responder chain.
/// In plain SwiftUI, `@Environment(\.undoManager)` is frequently NIL - no UIKit responder in the tree
/// provides one - so the delete registered with that nil manager is never reachable by the shake, and
/// "Undo Delete" silently does nothing. This host fixes it structurally: it embeds a tiny
/// `UIViewController` that (a) can become first responder, (b) becomes it on appear, and (c) vends a
/// STABLE `UndoManager` from its `undoManager` override. Registering the delete with THAT manager - the
/// same one the shake reaches through the responder chain - makes the gesture work.
///
/// Kept as a small, separable component (the host view + a coordinator holding the manager) so the
/// injection reads clearly: `StreamListView` overlays it and hands the vended manager to
/// `NoteDeletionController`, replacing the unreliable environment manager.
struct UndoManagerHost: UIViewControllerRepresentable {
    /// Called once with the stable `UndoManager` the hosted controller vends, so the composition root can
    /// inject it into the deletion controller. Fires on make (and is idempotent-safe for the caller).
    let onManager: (UndoManager) -> Void

    func makeUIViewController(context: Context) -> FirstResponderUndoController {
        let controller = FirstResponderUndoController()
        onManager(controller.stableUndoManager)
        return controller
    }

    func updateUIViewController(_ controller: FirstResponderUndoController, context: Context) {}

    /// A zero-size view controller that becomes first responder so its `undoManager` is the one the shake
    /// gesture resolves, and vends a single stable `UndoManager` for the app to register deletes on.
    final class FirstResponderUndoController: UIViewController {
        /// The one manager for the app's undoable actions. Stable for the controller's lifetime so a
        /// registered "Undo Delete" is still there when the user shakes.
        let stableUndoManager = UndoManager()

        override var undoManager: UndoManager? { stableUndoManager }

        override var canBecomeFirstResponder: Bool { true }

        override func viewDidLoad() {
            super.viewDidLoad()
            // Invisible: it exists only to hold first-responder status and vend the manager. The record
            // button and everything else still receive touches (this view has zero size).
            view.isUserInteractionEnabled = false
            view.frame = .zero
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // Become first responder so the shake gesture's responder-chain lookup reaches THIS
            // controller's `undoManager`. Re-asserted on each appear in case focus moved away.
            becomeFirstResponder()
        }
    }
}
