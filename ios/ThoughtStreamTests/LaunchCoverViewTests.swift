import XCTest
@testable import ThoughtStream

/// The launch cover (spec 0012) is a pure-visual view, but its bar-height math is extracted into the
/// testable static `LaunchCoverView.barHeight(bar:of:at:)`. These tests pin the contract the
/// animation depends on: heights are normalized 0...1, the row is not flat at any instant (bars
/// differ across indices), and each bar changes over time (it animates). SwiftUI view rendering is
/// not tested.
final class LaunchCoverViewTests: XCTestCase {
    private let count = LaunchCoverView.barCount

    func testBarPointHeightFloorsAndClamps() {
        let floor: CGFloat = 8
        let rowHeight: CGFloat = 64
        // A normalized 0 maps to the floor (no bar collapses to nothing); 1 maps to the full height.
        XCTAssertEqual(LaunchCoverView.barPointHeight(normalized: 0, floor: floor, rowHeight: rowHeight), floor)
        XCTAssertEqual(LaunchCoverView.barPointHeight(normalized: 1, floor: floor, rowHeight: rowHeight), rowHeight)
        // Out-of-range input clamps rather than overflowing the row.
        XCTAssertEqual(LaunchCoverView.barPointHeight(normalized: -0.5, floor: floor, rowHeight: rowHeight), floor)
        XCTAssertEqual(LaunchCoverView.barPointHeight(normalized: 2, floor: floor, rowHeight: rowHeight), rowHeight)
        // Monotonic between the endpoints.
        let mid = LaunchCoverView.barPointHeight(normalized: 0.5, floor: floor, rowHeight: rowHeight)
        XCTAssertGreaterThan(mid, floor)
        XCTAssertLessThan(mid, rowHeight)
    }

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

    func testWaveTravelsInReversedDirection() {
        // Feedback 0018: the traveling wave was reversed. The per-bar phase now indexes from the far
        // end, so at a fixed instant the height sequence is the mirror of the OLD (non-reversed)
        // formula. Reproduce the old formula here as the reference and assert the current output is its
        // reverse - this fails against the pre-0018 direction.
        func oldBarHeight(bar: Int, of count: Int, at t: Double) -> Double {
            let index = Double(bar) // old: phase indexed from bar 0 upward
            let phase = index * 0.9
            let primaryWave = sin(t * 3.1 + phase)
            let secondaryWave = sin(t * 5.7 + phase * 1.7)
            let combined = (primaryWave * 0.65 + secondaryWave * 0.35)
            return (combined + 1) / 2
        }
        for t in stride(from: 0.0, through: 3.0, by: 0.25) {
            for bar in 0..<count {
                let current = LaunchCoverView.barHeight(bar: bar, of: count, at: t)
                let mirrored = oldBarHeight(bar: count - 1 - bar, of: count, at: t)
                XCTAssertEqual(current, mirrored, accuracy: 1e-9,
                               "Bar \(bar) at t=\(t): wave should travel reversed (mirror of old formula)")
            }
        }
        // And it must NOT match the old, non-reversed sequence (the crest sweeps the other way now).
        // Pick a time where the row is clearly non-symmetric so the reversal is observable.
        let t = 0.4
        let current = (0..<count).map { LaunchCoverView.barHeight(bar: $0, of: count, at: t) }
        let old = (0..<count).map { oldBarHeight(bar: $0, of: count, at: t) }
        XCTAssertNotEqual(current, old, "Reversed wave must differ from the old direction")
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
