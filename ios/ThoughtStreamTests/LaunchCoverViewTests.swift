import XCTest
@testable import ThoughtStream

/// The launch cover (spec 0012) is a pure-visual view, but its bar-height math is extracted into the
/// testable static `LaunchCoverView.barHeight(bar:of:at:)`. These tests pin the contract the
/// animation depends on: heights are normalized 0...1, the row is not flat at any instant (bars
/// differ across indices), and each bar changes over time (it animates). SwiftUI view rendering is
/// not tested.
final class LaunchCoverViewTests: XCTestCase {
    private let count = LaunchCoverView.barCount

    func testHeightsStayWithinUnitInterval() {
        // Sample every bar across a spread of times; a height outside 0...1 would map to a negative or
        // overflowing frame.
        for t in stride(from: 0.0, through: 5.0, by: 0.05) {
            for bar in 0..<count {
                let height = LaunchCoverView.barHeight(bar: bar, of: count, at: t)
                XCTAssertGreaterThanOrEqual(height, 0, "Bar \(bar) at t=\(t) below 0")
                XCTAssertLessThanOrEqual(height, 1, "Bar \(bar) at t=\(t) above 1")
            }
        }
    }

    func testRowIsNotFlatAtAGivenInstant() {
        // At a fixed instant the bars must not all share one height, or the row reads as a solid block
        // rather than a waveform.
        let t = 1.234
        let heights = (0..<count).map { LaunchCoverView.barHeight(bar: $0, of: count, at: t) }
        let distinct = Set(heights.map { ($0 * 1000).rounded() })
        XCTAssertGreaterThan(distinct.count, 1, "Bars must differ across indices at a given time")
    }

    func testBarChangesOverTime() {
        // A single bar sampled at different times must move, or it is not animating.
        let bar = 3
        let atStart = LaunchCoverView.barHeight(bar: bar, of: count, at: 0)
        var moved = false
        for t in stride(from: 0.05, through: 2.0, by: 0.05) {
            if abs(LaunchCoverView.barHeight(bar: bar, of: count, at: t) - atStart) > 0.01 {
                moved = true
                break
            }
        }
        XCTAssertTrue(moved, "A bar must change height over time so the row animates")
    }

    func testEveryBarMovesOverTime() {
        // Not just one bar: every bar in the row must animate, so no column looks frozen.
        for bar in 0..<count {
            let samples = stride(from: 0.0, through: 2.0, by: 0.1).map {
                LaunchCoverView.barHeight(bar: bar, of: count, at: $0)
            }
            let distinct = Set(samples.map { ($0 * 1000).rounded() })
            XCTAssertGreaterThan(distinct.count, 1, "Bar \(bar) never moves over time")
        }
    }
}
