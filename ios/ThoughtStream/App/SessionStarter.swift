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
/// Lives on `AppDependencies` so the one composition root owns it. Hands-free callers (a Siri
/// intent, CarPlay) reach the live instance through `AppDependencies.sessionStarter`, which routes
/// to the shared latch below so a request survives a COLD launch: an intent that fires before the
/// composition root has resolved (very common - Siri cold-starts the app) sets the latch, and the
/// route seeds itself from it the moment it is created. Without that, the `?` on an unresolved
/// `shared` would silently drop the very request that launched the app.
@MainActor
final class PendingSessionRoute: ObservableObject, SessionStarter {
    /// Process-wide latch for a start requested before a route exists (a cold hands-free launch).
    /// The next route created reads and clears it, so exactly one session opens. Main-actor isolated,
    /// so no locking is needed; hands-free callers already hop to the main actor. `private(set)` so
    /// only this type's own latch operations mutate it; callers set it through `latchColdStart()` and
    /// clear it by creating a route (or, in tests, `clearColdStartLatch()`).
    static private(set) var pendingColdStart = false

    /// Record a start that arrived before any route existed (a cold hands-free launch). The next
    /// route created adopts it. Kept here so the latch's only writer is `PendingSessionRoute`.
    static func latchColdStart() {
        pendingColdStart = true
    }

    /// Clear the cold-start latch without adopting it. For tests that need a clean process-wide
    /// starting state; production clears the latch only by creating a route that adopts it.
    static func clearColdStartLatch() {
        pendingColdStart = false
    }

    /// True when a hands-free or in-app caller has asked to start a session and the root has not yet
    /// consumed it. The root presents `DictationView` while this is set, then calls `consume()`.
    @Published private(set) var startRequested = false

    init() {
        // Adopt any start that arrived before this route existed (a cold Siri/CarPlay launch), then
        // clear the latch so a later route does not re-open a stale session.
        if Self.pendingColdStart {
            startRequested = true
            Self.pendingColdStart = false
        }
    }

    func startNewSession() {
        startRequested = true
    }

    /// Mark the pending start as handled, once the root has opened the dictation session. Safe to
    /// call when nothing is pending.
    func consume() {
        startRequested = false
    }

    /// The pure decision for turning the pending-route state into a "present dictation?" answer,
    /// split out from `StreamListView` so it is unit-testable without SwiftUI. A pure, static
    /// function of its input: the view holds no routing logic of its own and the routing is proven
    /// directly. A pending start opens dictation; nothing pending closes it. Making presentation a
    /// pure function of `startRequested` (rather than only reacting to the flag's edges) means a
    /// start requested while the app was backgrounded still opens on first appear, and a start
    /// requested again right after a session ends re-opens once the previous one has been consumed.
    static func shouldPresent(startRequested: Bool) -> Bool {
        startRequested
    }
}

/// The starter handed to hands-free callers before the composition root has resolved (a cold
/// launch): it records the request on `PendingSessionRoute.pendingColdStart`, which the first real
/// route adopts. This closes the cold-launch gap where an intent fires before `AppDependencies` is
/// ready, so the request that launched the app is never lost.
@MainActor
final class ColdStartSessionStarter: SessionStarter {
    func startNewSession() {
        PendingSessionRoute.latchColdStart()
    }
}
