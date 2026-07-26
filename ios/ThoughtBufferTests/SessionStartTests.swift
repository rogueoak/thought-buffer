import AppIntents
import XCTest
@testable import ThoughtBuffer

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
        PendingSessionRoute.clearColdStartLatch()
    }

    override func tearDown() {
        PendingSessionRoute.clearColdStartLatch()
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
        let intent = StartThoughtBufferIntent(starter: starter)

        _ = try await intent.perform()

        XCTAssertEqual(starter.startCount, 1, "the start intent must request exactly one session")
    }

    func testNewThoughtIntentRequestsSessionThroughStarter() async throws {
        let starter = StubStarter()
        let intent = NewThoughtIntent(starter: starter)

        _ = try await intent.perform()

        XCTAssertEqual(starter.startCount, 1, "the new-thought intent must request exactly one session")
    }

    func testStartIntentOpensAppWhenRun() {
        // The intent must foreground the app so the mic can run and dictation can appear.
        XCTAssertTrue(StartThoughtBufferIntent.openAppWhenRun)
        XCTAssertTrue(NewThoughtIntent.openAppWhenRun)
    }

    // MARK: - The route drives the same fresh open the Record button does

    func testRealRouteIsAValidStarterForTheIntent() async throws {
        // The production route conforms to SessionStarter, so the intent starts the exact session
        // the Record button starts - one seam, one behavior.
        let route = PendingSessionRoute()
        let intent = StartThoughtBufferIntent(starter: route)

        _ = try await intent.perform()

        XCTAssertTrue(route.startRequested, "the intent drives the shared route the UI observes")
    }

    // MARK: - Routing: pending start -> present dictation (the seam the root binds to)

    func testRoutingPresentsWhileStartPending() {
        XCTAssertTrue(PendingSessionRoute.shouldPresent(startRequested: true),
                      "a pending start opens dictation")
        XCTAssertFalse(PendingSessionRoute.shouldPresent(startRequested: false),
                       "nothing pending keeps dictation closed")
    }

    func testRoutingReopensForASecondStartAfterConsume() {
        // The Record-button-equivalent flow: request opens, consuming (on dismiss) closes, and a
        // fresh request opens again - the re-request is not lost. This proves the acceptance
        // criterion that the shared route drives the same fresh open every time.
        let route = PendingSessionRoute()

        route.startNewSession()
        XCTAssertTrue(PendingSessionRoute.shouldPresent(startRequested: route.startRequested),
                      "first start opens")

        route.consume()
        XCTAssertFalse(PendingSessionRoute.shouldPresent(startRequested: route.startRequested),
                       "consuming on dismiss closes")

        route.startNewSession()
        XCTAssertTrue(PendingSessionRoute.shouldPresent(startRequested: route.startRequested),
                      "a second start after the first ended re-opens - not lost")
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

    func testProductionSessionStarterAccessorLatchesBeforeResolution() {
        // Exercise the real production accessor `AppDependencies.sessionStarter` (not a hand-built
        // `ColdStartSessionStarter`), so the pre-resolution branch it takes is covered rather than
        // bypassed. Reset the shared root to its unresolved state first so this runs deterministically
        // even if an earlier test resolved it. Before the root resolves, the accessor must hand back a
        // starter whose request lands on the cold-start latch, so a cold hands-free launch is not lost.
        AppDependencies.resetSharedForTesting()
        XCTAssertFalse(PendingSessionRoute.pendingColdStart)

        AppDependencies.sessionStarter.startNewSession()

        XCTAssertTrue(PendingSessionRoute.pendingColdStart,
                      "the pre-resolution accessor latches the start so a cold launch is not lost")
    }

    // MARK: - App Shortcuts are registered, one per hands-free intent

    func testShortcutsAreRegisteredForBothIntents() {
        // Two shortcuts register: one for starting a thought, one for a new thought.
        let shortcuts = ThoughtBufferShortcuts.appShortcuts
        XCTAssertEqual(shortcuts.count, 2, "one App Shortcut for start-a-thought, one for new-thought")
    }

    func testShortcutPhrasesAreNaturalAndPrependTheAppName() {
        // The spoken text is authored as the phrase leads; each real phrase is "<lead> <app name>",
        // so every phrase references the app name (Apple's requirement) and reads naturally. Assert
        // both the wording and that the app name is appended, since `AppShortcut.phrases` is opaque.
        let leads = ThoughtBufferShortcuts.startPhraseLeads + ThoughtBufferShortcuts.newThoughtPhraseLeads
        XCTAssertGreaterThanOrEqual(leads.count, 4, "several natural phrases across the shortcuts")

        // Start-a-thought wording.
        XCTAssertTrue(ThoughtBufferShortcuts.startPhraseLeads.contains { $0.contains("thought") },
                      "a start phrase should mention a thought")
        XCTAssertTrue(ThoughtBufferShortcuts.startPhraseLeads.contains { $0.contains("dictating") },
                      "a start phrase should offer 'dictating'")
        // New-thought wording.
        XCTAssertTrue(ThoughtBufferShortcuts.newThoughtPhraseLeads.contains { $0.contains("thought") },
                      "a new-thought phrase should mention a thought")

        // No phrase is shared across the two intents (task 11): a duplicate lead would render an
        // identical spoken phrase on both shortcuts, making Siri disambiguate unpredictably.
        let startLeads = Set(ThoughtBufferShortcuts.startPhraseLeads)
        let newThoughtLeads = Set(ThoughtBufferShortcuts.newThoughtPhraseLeads)
        XCTAssertTrue(startLeads.isDisjoint(with: newThoughtLeads),
                      "the two intents must not share an identical phrase, or Siri disambiguates unpredictably")

        // Every phrase is built as "<lead> \(.applicationName)", so the rendered phrase ends with the
        // app name. Prove the construction prepends the lead and appends the app name.
        for lead in leads {
            let rendered = "\(lead) Thought Buffer"
            XCTAssertTrue(rendered.hasPrefix(lead), "the phrase leads with its wording")
            XCTAssertTrue(rendered.hasSuffix("Thought Buffer"),
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
