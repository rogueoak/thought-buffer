import Foundation

/// The single headless "start a new dictation session" entry point, shared by every way a session
/// can begin: the in-app Record button, the Siri App Intent, and the CarPlay action. Depending on
/// this protocol (rather than the concrete route) keeps callers - the App Intent especially -
/// unit-testable with a stub that records the request instead of touching any UI.
///
/// "Start a session" means "route to a fresh `DictationView`", which begins capture in its `.task`.
/// One method, one meaning, so all three entry points start a session identically.
@MainActor
protocol SessionStarter: AnyObject {
    /// Request that the app open a fresh dictation session and begin capturing. Idempotent: a
    /// second request before the first is consumed collapses into one pending start.
    func startNewSession()
}

/// The concrete session starter and the app's pending-route mechanism in one small type: it holds a
/// "start requested" flag that the root view observes and consumes on launch / foreground. An
/// `ObservableObject` so SwiftUI re-renders when a start is requested from outside the view tree (a
/// Siri intent or CarPlay), which is exactly when the app was not already on screen.
///
/// Lives on `AppDependencies` so the one composition root owns it. The App Intent, which the system
/// instantiates outside the SwiftUI tree, reaches the live instance through
/// `AppDependencies.shared` (see `AppDependencies`).
@MainActor
final class PendingSessionRoute: ObservableObject, SessionStarter {
    /// True when a hands-free or in-app caller has asked to start a session and the root has not yet
    /// consumed it. The root presents `DictationView` while this is set, then calls `consume()`.
    @Published private(set) var startRequested = false

    func startNewSession() {
        startRequested = true
    }

    /// Mark the pending start as handled, once the root has opened the dictation session. Safe to
    /// call when nothing is pending.
    func consume() {
        startRequested = false
    }
}
