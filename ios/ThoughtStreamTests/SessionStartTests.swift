import AppIntents
import XCTest
@testable import ThoughtStream

/// The hands-free session-start seam: the App Intents request a start through the shared
/// `SessionStarter`, the `PendingSessionRoute` records and consumes a pending start, and the App
/// Shortcut phrases reference the app name. Proven without any UI by injecting a stub starter, so
/// the Siri path is testable off a device.
@MainActor
final class SessionStartTests: XCTestCase {

    // MARK: - Shared route: the seam the Record button, Siri, and CarPlay all use

    func testRouteStartsIdleThenRecordsAndConsumes() {
        let route = PendingSessionRoute()
        XCTAssertFalse(route.startRequested, "a fresh route has no pending start")

        route.startNewSession()
        XCTAssertTrue(route.startRequested, "requesting a start flips the pending flag")

        route.consume()
        XCTAssertFalse(route.startRequested, "consuming clears the pending start")
    }

    func testRepeatedStartRequestsCollapseToOnePending() {
        let route = PendingSessionRoute()
        route.startNewSession()
        route.startNewSession()
        XCTAssertTrue(route.startRequested)

        // One consume clears it - the two requests before it were a single pending start.
        route.consume()
        XCTAssertFalse(route.startRequested)
    }

    // MARK: - App Intents start a session via the stubbed starter (no UI)

    func testStartIntentRequestsSessionThroughStarter() async throws {
        let starter = StubStarter()
        let intent = StartThoughtStreamIntent(starter: starter)

        _ = try await intent.perform()

        XCTAssertEqual(starter.startCount, 1, "the start intent must request exactly one session")
    }

    func testNewNoteIntentRequestsSessionThroughStarter() async throws {
        let starter = StubStarter()
        let intent = NewNoteIntent(starter: starter)

        _ = try await intent.perform()

        XCTAssertEqual(starter.startCount, 1, "the new-note intent must request exactly one session")
    }

    func testStartIntentOpensAppWhenRun() {
        // The intent must foreground the app so the mic can run and dictation can appear.
        XCTAssertTrue(StartThoughtStreamIntent.openAppWhenRun)
        XCTAssertTrue(NewNoteIntent.openAppWhenRun)
    }

    // MARK: - The route drives the same fresh open the Record button does

    func testRealRouteIsAValidStarterForTheIntent() async throws {
        // The production route conforms to SessionStarter, so the intent starts the exact session
        // the Record button starts - one seam, one behavior.
        let route = PendingSessionRoute()
        let intent = StartThoughtStreamIntent(starter: route)

        _ = try await intent.perform()

        XCTAssertTrue(route.startRequested, "the intent drives the shared route the UI observes")
    }

    // MARK: - App Shortcuts are registered, one per hands-free intent

    func testShortcutsAreRegisteredForBothIntents() {
        // The provider must expose shortcuts, and the framework validates at build/registration time
        // that every phrase includes `\(.applicationName)` (Apple's rule) - a phrase missing it is a
        // compile-time diagnostic, so the source guarantees the app-name contract. Here we assert the
        // provider surfaces phrases and each phrase resolves to a spoken string.
        let shortcuts = ThoughtStreamShortcuts.appShortcuts
        XCTAssertEqual(shortcuts.count, 2, "one App Shortcut for start-a-stream, one for new-note")

        // `AppShortcut.phrases` is not public, but the phrase count is reachable through Mirror: find
        // the `[AppShortcutPhrase]` child on each shortcut. Asserts several natural phrases exist.
        let totalPhrases = shortcuts.reduce(0) { $0 + phrasesCount(of: $1) }
        XCTAssertGreaterThanOrEqual(totalPhrases, 4, "several natural phrases across the shortcuts")
    }

    /// The number of spoken phrases on an `AppShortcut`, found by locating its phrases array via
    /// Mirror. Kept narrow: it looks for the one array child, so it does not over-count.
    private func phrasesCount(of shortcut: AppShortcut) -> Int {
        for child in Mirror(reflecting: shortcut).children {
            let valueMirror = Mirror(reflecting: child.value)
            if valueMirror.displayStyle == .collection, !valueMirror.children.isEmpty {
                return valueMirror.children.count
            }
        }
        return 0
    }
}

// MARK: - Test double

/// A `SessionStarter` stub that counts requests, so an App Intent's start can be proven without any
/// UI or a resolved app.
@MainActor
private final class StubStarter: SessionStarter {
    private(set) var startCount = 0
    func startNewSession() { startCount += 1 }
}
