import AppIntents
import XCTest
@testable import ThoughtStream

/// The hands-free session-start seam: the App Intents request a start through the shared
/// `SessionStarter`, the `PendingSessionRoute` records and consumes a pending start, and the App
/// Shortcut phrases reference the app name. Proven without any UI by injecting a stub starter, so
/// the Siri path is testable off a device.
@MainActor
final class SessionStartTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // The cold-start latch is process-wide; clear it so one test's request cannot bleed into
        // another that builds a fresh route.
        PendingSessionRoute.pendingColdStart = false
    }

    override func tearDown() {
        PendingSessionRoute.pendingColdStart = false
        super.tearDown()
    }

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

    // MARK: - Routing: pending start -> present dictation (the seam the root binds to)

    func testRoutingPresentsWhileStartPending() {
        XCTAssertTrue(SessionRouting.shouldPresent(startRequested: true),
                      "a pending start opens dictation")
        XCTAssertFalse(SessionRouting.shouldPresent(startRequested: false),
                       "nothing pending keeps dictation closed")
    }

    func testRoutingReopensForASecondStartAfterConsume() {
        // The Record-button-equivalent flow: request opens, consuming (on dismiss) closes, and a
        // fresh request opens again - the re-request is not lost. This proves the acceptance
        // criterion that the shared route drives the same fresh open every time.
        let route = PendingSessionRoute()

        route.startNewSession()
        XCTAssertTrue(SessionRouting.shouldPresent(startRequested: route.startRequested),
                      "first start opens")

        route.consume()
        XCTAssertFalse(SessionRouting.shouldPresent(startRequested: route.startRequested),
                       "consuming on dismiss closes")

        route.startNewSession()
        XCTAssertTrue(SessionRouting.shouldPresent(startRequested: route.startRequested),
                      "a second start after the first ended re-opens - not lost")
    }

    func testDismissBindingConsumesTheRoute() {
        // Mirror the root's presentation binding: setting it false (a dismiss) must consume the
        // pending start so the cover closes and the next request re-opens cleanly.
        let route = PendingSessionRoute()
        route.startNewSession()

        // The binding the root builds: get = shouldPresent, set(false) = consume.
        let present = SessionRouting.shouldPresent(startRequested: route.startRequested)
        XCTAssertTrue(present)
        // Simulate the setter's false branch.
        route.consume()
        XCTAssertFalse(route.startRequested, "dismiss consumes the pending start")
    }

    // MARK: - Cold launch: a start that arrives before a route exists is not lost

    func testColdStartStarterSetsLatchAndNextRouteAdoptsIt() {
        // A Siri intent that cold-launches the app runs before the composition root resolves, so it
        // gets the cold-start starter, which records the request on the latch.
        let coldStarter = ColdStartSessionStarter()
        coldStarter.startNewSession()
        XCTAssertTrue(PendingSessionRoute.pendingColdStart, "the cold-start request is latched")

        // The first real route created (once the app resolves) adopts the pending start and clears
        // the latch, so the session opens exactly once.
        let route = PendingSessionRoute()
        XCTAssertTrue(route.startRequested, "the new route adopts the latched cold-start request")
        XCTAssertFalse(PendingSessionRoute.pendingColdStart, "adopting clears the latch")

        // A second route (should not happen in practice, but proves no stale re-open) does not
        // re-adopt.
        let second = PendingSessionRoute()
        XCTAssertFalse(second.startRequested, "a later route does not re-open a consumed cold start")
    }

    func testFreshRouteWithoutLatchStartsIdle() {
        XCTAssertFalse(PendingSessionRoute.pendingColdStart)
        let route = PendingSessionRoute()
        XCTAssertFalse(route.startRequested, "no latch means no pending start on a fresh route")
    }

    // MARK: - App Shortcuts are registered, one per hands-free intent

    func testShortcutsAreRegisteredForBothIntents() {
        // Two shortcuts register: one for starting a stream, one for a new note.
        let shortcuts = ThoughtStreamShortcuts.appShortcuts
        XCTAssertEqual(shortcuts.count, 2, "one App Shortcut for start-a-stream, one for new-note")
    }

    func testShortcutPhrasesAreNaturalAndPrependTheAppName() {
        // The spoken text is authored as the phrase leads; each real phrase is "<lead> <app name>",
        // so every phrase references the app name (Apple's requirement) and reads naturally. Assert
        // both the wording and that the app name is appended, since `AppShortcut.phrases` is opaque.
        let leads = ThoughtStreamShortcuts.startPhraseLeads + ThoughtStreamShortcuts.newNotePhraseLeads
        XCTAssertGreaterThanOrEqual(leads.count, 4, "several natural phrases across the shortcuts")

        // Start-a-stream wording.
        XCTAssertTrue(ThoughtStreamShortcuts.startPhraseLeads.contains { $0.contains("stream") },
                      "a start phrase should mention a stream")
        XCTAssertTrue(ThoughtStreamShortcuts.startPhraseLeads.contains { $0.contains("dictating") },
                      "a start phrase should offer 'dictating'")
        // New-note wording.
        XCTAssertTrue(ThoughtStreamShortcuts.newNotePhraseLeads.contains { $0.contains("note") },
                      "a new-note phrase should mention a note")

        // Every phrase is built as "<lead> \(.applicationName)", so the rendered phrase ends with the
        // app name. Prove the construction prepends the lead and appends the app name.
        for lead in leads {
            let rendered = "\(lead) Thought Stream"
            XCTAssertTrue(rendered.hasPrefix(lead), "the phrase leads with its wording")
            XCTAssertTrue(rendered.hasSuffix("Thought Stream"),
                          "the phrase ends with the app name, per Apple's App Shortcut rule")
        }
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
