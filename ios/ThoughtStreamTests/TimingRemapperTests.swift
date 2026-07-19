import XCTest
@testable import ThoughtStream

/// The pure timing remap (spec 0019): given original paragraph timings and the removed silence
/// ranges, shift each paragraph start left by the removed duration preceding it. Durations stay
/// unchanged (the invariant guarantees no removed range lies inside a paragraph), and the count and
/// alignment are preserved.
final class TimingRemapperTests: XCTestCase {
    private func removed(_ pairs: [(Double, Double)]) -> [SilenceTrimmer.KeepRange] {
        pairs.map { SilenceTrimmer.KeepRange(start: $0.0, end: $0.1) }
    }

    func testNoRemovedRangesReturnsTimingsUnchanged() {
        let timings = [ParagraphTiming(start: 0, duration: 2), ParagraphTiming(start: 5, duration: 3)]
        let out = TimingRemapper.remap(timings: timings, removedRanges: [])
        XCTAssertEqual(out, timings)
    }

    func testSilenceBeforeAParagraphShiftsItLeft() {
        // Two paragraphs: [0,2) and [5,3). A 2.5s silence removed at [2.5,5.0) sits between them.
        // The second paragraph shifts left by 2.5 -> starts at 2.5, duration unchanged.
        let timings = [ParagraphTiming(start: 0, duration: 2), ParagraphTiming(start: 5, duration: 3)]
        let out = TimingRemapper.remap(timings: timings, removedRanges: removed([(2.5, 5.0)]))
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(out[0].duration, 2, accuracy: 0.001)
        XCTAssertEqual(out[1].start, 2.5, accuracy: 0.001)
        XCTAssertEqual(out[1].duration, 3, accuracy: 0.001)
    }

    func testSilenceBeforeTheFirstParagraphShiftsEverything() {
        // Leading silence removed at [0,2) before the first paragraph at 3.
        let timings = [ParagraphTiming(start: 3, duration: 2), ParagraphTiming(start: 8, duration: 1)]
        let out = TimingRemapper.remap(timings: timings, removedRanges: removed([(0, 2)]))
        XCTAssertEqual(out[0].start, 1, accuracy: 0.001)
        XCTAssertEqual(out[1].start, 6, accuracy: 0.001)
    }

    func testBackToBackSilencesAccumulateShift() {
        // Three paragraphs with two removed silences between them.
        // Removed: [2,4) (2s) and [6,7.5) (1.5s).
        let timings = [
            ParagraphTiming(start: 0, duration: 2),   // before any removal
            ParagraphTiming(start: 4, duration: 2),    // after first removal -> shift 2
            ParagraphTiming(start: 7.5, duration: 2),  // after both removals -> shift 3.5
        ]
        let out = TimingRemapper.remap(timings: timings, removedRanges: removed([(2, 4), (6, 7.5)]))
        XCTAssertEqual(out[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(out[1].start, 2, accuracy: 0.001)
        XCTAssertEqual(out[2].start, 4, accuracy: 0.001)
        // Durations all preserved.
        XCTAssertEqual(out.map { $0.duration }, [2, 2, 2])
    }

    func testCountAndAlignmentPreserved() {
        let timings = (0..<5).map { ParagraphTiming(start: Double($0) * 10, duration: 3) }
        let out = TimingRemapper.remap(timings: timings, removedRanges: removed([(5, 8)]))
        XCTAssertEqual(out.count, timings.count)
        // The first paragraph (start 0) is before the removal, unshifted; the rest shift by 3.
        XCTAssertEqual(out[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(out[1].start, 7, accuracy: 0.001)   // 10 - 3
        XCTAssertEqual(out[4].start, 37, accuracy: 0.001)  // 40 - 3
    }

    func testZeroLengthPlaceholderKeepsZeroDuration() {
        // A text-only paragraph placeholder (0 duration) still shifts its start but keeps 0 duration.
        let timings = [ParagraphTiming(start: 0, duration: 2), ParagraphTiming(start: 6, duration: 0)]
        let out = TimingRemapper.remap(timings: timings, removedRanges: removed([(2, 4)]))
        XCTAssertEqual(out[1].start, 4, accuracy: 0.001)
        XCTAssertEqual(out[1].duration, 0, accuracy: 0.001)
    }
}
