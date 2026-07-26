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
/// CRITICAL (engineer + architect review): becoming first responder ONCE in `viewDidAppear` is not
/// enough. The search field is now on every screen, and focusing it (or the title/body editor) makes
/// THAT text field the first responder; when it resigns, first responder does NOT return to this host,
/// so a shake resolves against the wrong (or nil) manager and shake-to-undo silently breaks - the exact
/// bug this PR fixes. So the host RE-CLAIMS first responder whenever focus should return to it: on
/// keyboard hide, on a text field ending editing, and on the app becoming active. That keeps the shake
/// reaching `ThoughtDeletionController`'s injected manager after any in-app editing.
///
/// Kept as a small, separable component (the host view + a coordinator holding the manager) so the
/// injection reads clearly: `StreamListView` overlays it and hands the vended manager to
/// `ThoughtDeletionController`, replacing the unreliable environment manager.
struct UndoManagerHost: UIViewControllerRepresentable {
    /// Called once with the stable `UndoManager` the hosted controller vends, so the composition root can
    /// inject it into the deletion controller. Fires on make (and is idempotent-safe for the caller).
    let onManager: (UndoManager) -> Void

    /// A monotonic re-home signal for the split view (spec 0022). Under a `NavigationSplitView` the first
    /// responder moves between COLUMNS as the user picks a folder or a thought, and a plain column switch
    /// fires none of the text-field / keyboard notifications the host already listens for - so the shake
    /// could resolve against a stale column's responder chain. The composition root bumps this whenever the
    /// active column changes (sidebar folder / detail thought selection), and the host re-claims first
    /// responder on the change, re-homing the shake to its vended manager regardless of active column. It
    /// stays 0 on the compact stack (one screen at a time), so this is a no-op there.
    var reclaimTrigger: Int = 0

    /// Whether a delete is currently pending (spec 0022), so the host's layout-pass self-heal (rotate /
    /// resize / multitasking) only re-claims first responder when the shake would have something to undo.
    /// The composition root passes the deletion controller's pending state.
    var pendingDelete: Bool = false

    func makeUIViewController(context: Context) -> FirstResponderUndoController {
        let controller = FirstResponderUndoController()
        // Hand the vended manager back OUTSIDE the current view-update pass (feedback 0020). This runs
        // during SwiftUI's update, and `onManager` mutates the composition root's `@State`
        // (`undoManagerInjected`); doing that synchronously here is the "Modifying state during view
        // update, this will cause undefined behavior" warning, which also made SwiftUI re-run the pass and
        // the list title lazy-render on navigation. Deferring to the next main-actor tick injects the
        // manager just as reliably (it is needed only when a shake happens, long after the first render)
        // without mutating state mid-update.
        let manager = controller.stableUndoManager
        DispatchQueue.main.async { onManager(manager) }
        return controller
    }

    func updateUIViewController(_ controller: FirstResponderUndoController, context: Context) {
        controller.pendingDelete = pendingDelete
        // A column change in the split view (spec 0022): re-home first responder so the shake keeps reaching
        // the vended manager after focus moved between columns. Guarded on an actual change so an unrelated
        // SwiftUI update does not yank focus from a field the user is editing (the reclaim itself also
        // skips an actively-edited field).
        if controller.lastReclaimTrigger != reclaimTrigger {
            controller.lastReclaimTrigger = reclaimTrigger
            controller.reclaimFirstResponderFromSplitColumnChange()
        }
    }

    /// A zero-size view controller that becomes first responder so its `undoManager` is the one the shake
    /// gesture resolves, and vends a single stable `UndoManager` for the app to register deletes on. It
    /// RE-CLAIMS first responder after any text field steals it (keyboard hide, end-editing) and when the
    /// app returns to the foreground, so the shake keeps reaching the vended manager.
    final class FirstResponderUndoController: UIViewController {
        /// The one manager for the app's undoable actions. Stable for the controller's lifetime so a
        /// registered "Undo Delete" is still there when the user shakes.
        let stableUndoManager = UndoManager()

        /// The last split-column re-home trigger value seen (spec 0022), so a re-home fires only when the
        /// split view's active column actually changed - not on every SwiftUI update.
        var lastReclaimTrigger = 0

        override var undoManager: UndoManager? { stableUndoManager }

        override var canBecomeFirstResponder: Bool { true }

        override func viewDidLoad() {
            super.viewDidLoad()
            // Invisible: it exists only to hold first-responder status and vend the manager. The record
            // button and everything else still receive touches (this view has zero size).
            view.isUserInteractionEnabled = false
            view.frame = .zero

            // Re-claim first responder whenever focus should return to this host, so a shake keeps
            // resolving against the vended manager after the user edited a text field (search, title,
            // body). The keyboard-hide and end-editing notifications fire as a field resigns; the
            // did-become-active notification covers returning from the background; the orientation-change
            // notification covers an iPad ROTATE (spec 0022), which - like a resize / multitasking change -
            // can churn the split view's responder chain without any text/keyboard event or a
            // sidebar/detail selection change, so a pending delete would otherwise lose the shake.
            let center = NotificationCenter.default
            for name in [
                UIResponder.keyboardDidHideNotification,
                UITextField.textDidEndEditingNotification,
                UITextView.textDidEndEditingNotification,
                UIApplication.didBecomeActiveNotification,
                UIDevice.orientationDidChangeNotification,
            ] {
                center.addObserver(
                    self,
                    selector: #selector(reclaimFirstResponder),
                    name: name,
                    object: nil
                )
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // Become first responder so the shake gesture's responder-chain lookup reaches THIS
            // controller's `undoManager`.
            reclaimFirstResponder()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            // Self-heal on a layout pass (spec 0022): an iPad RESIZE / multitasking (Split View, Slide Over)
            // or a rotate re-lays-out the split view and can drop this host from the active responder chain
            // with NO text/keyboard notification and no selection change. A layout pass is the reliable
            // signal for those, so re-claim here too - the reclaim is guarded (it no-ops if already first
            // responder and never steals from an actively-edited field), so this is cheap and safe to run
            // on every layout. Only worth doing while a delete is pending (the shake has nothing to reach
            // otherwise), which keeps the common no-pending case a single cheap check.
            if pendingDelete { reclaimFirstResponder() }
        }

        /// Whether a delete is pending, so the layout-pass self-heal only fires when the shake would have
        /// something to undo. Set by the composition root alongside the deletion controller's pending state.
        var pendingDelete = false

        /// Reclaim first responder unless it is already ours or a text field is CURRENTLY being edited
        /// (a notification can fire while another field is taking over focus; stealing it back then would
        /// dismiss the keyboard). Deferred to the next runloop tick so it runs AFTER the resigning field
        /// has fully given up first responder, avoiding a claim/resign fight.
        @objc private func reclaimFirstResponder() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.viewIfLoaded?.window != nil else { return }
                if self.isFirstResponder { return }
                // Do not steal focus from a field the user is actively editing.
                if self.view.window?.findFirstResponder() is UITextInput { return }
                self.becomeFirstResponder()
            }
        }

        /// Re-home first responder after the split view's active column changed (spec 0022). Same guarded
        /// reclaim as the notification path (deferred a tick, skipped while a field is being edited), exposed
        /// so the composition root can trigger it on a column selection change that fires no text/keyboard
        /// notification.
        func reclaimFirstResponderFromSplitColumnChange() {
            reclaimFirstResponder()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

private extension UIView {
    /// The current first responder in this view's window subtree, or nil. Used so the undo host does not
    /// yank first responder away from a text field the user is actively editing.
    func findFirstResponder() -> UIResponder? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let responder = subview.findFirstResponder() { return responder }
        }
        return nil
    }
}
