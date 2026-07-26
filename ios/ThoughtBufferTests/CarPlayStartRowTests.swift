import CarPlay
import XCTest
@testable import ThoughtBuffer

/// The CarPlay recordings browser keeps the "Start a thought" row from spec 0005 (spec 0008):
/// tapping it must request a session through the shared `SessionStarter`, the same seam the Record
/// button and Siri use. Proven by firing the row's handler and asserting the injected starter is
/// called - no connected CarPlay scene needed, since the row builder is a static, closure-driven
/// factory.
@MainActor
final class CarPlayStartRowTests: XCTestCase {

    func testStartRowFiresTheStartClosure() {
        var startCount = 0
        let item = CarPlaySceneDelegate.makeStartItem { startCount += 1 }

        // The row exists and reads as the start action.
        XCTAssertEqual(item.text, "Start a thought")

        // Fire the row's tap handler the way CarPlay would; it must call the start closure and then
        // the completion handler exactly once.
        let done = expectation(description: "handler completion called")
        item.handler?(item) { done.fulfill() }

        wait(for: [done], timeout: 1)
        XCTAssertEqual(startCount, 1, "tapping the Start row requests exactly one session")
    }

    func testStartRowRoutesThroughSharedSessionStarter() {
        // The production row routes to `AppDependencies.sessionStarter`. Reset the shared root to its
        // unresolved state so the accessor takes its cold-start latch path deterministically, then
        // fire a row wired exactly as production wires it and assert the shared starter was reached.
        AppDependencies.resetSharedForTesting()
        PendingSessionRoute.clearColdStartLatch()

        let item = CarPlaySceneDelegate.makeStartItem {
            AppDependencies.sessionStarter.startNewSession()
        }
        let done = expectation(description: "completion")
        item.handler?(item) { done.fulfill() }
        wait(for: [done], timeout: 1)

        XCTAssertTrue(PendingSessionRoute.pendingColdStart,
                      "the Start row reaches the shared session starter")
        PendingSessionRoute.clearColdStartLatch()
    }
}
