import XCTest
@testable import ThoughtStream

/// Feedback 0012: the pure grouping policy that replaces "one finalized result = one paragraph" with
/// pause-based grouping. A mid-thought breath (small gap) flows into the current paragraph; a real
/// silence (gap at or above the threshold) starts a new one; an analysis start (a pause/resume seam)
/// always forces a break; and a degenerate range never crashes the gap math.
final class ParagraphGrouperTests: XCTestCase {

    /// The very first segment of a session has no prior anchor, so it starts a new paragraph even
    /// though it is not flagged as an analysis start.
    func testFirstSegmentStartsNewParagraph() {
        var grouper = ParagraphGrouper()
        let decision = grouper.decide(startSeconds: 0, durationSeconds: 1, isAnalysisStart: false)
        XCTAssertEqual(decision, .newParagraph)
    }

    /// A small gap (well below the 1.5s threshold) between two segments flows the second into the
    /// current paragraph - the whole point of the fix.
    func testSmallGapAppendsToCurrent() {
        var grouper = ParagraphGrouper()
        _ = grouper.decide(startSeconds: 0, durationSeconds: 1, isAnalysisStart: false) // ends at 1.0
        // Next segment starts at 1.4: a 0.4s gap, below threshold -> flow.
        let decision = grouper.decide(startSeconds: 1.4, durationSeconds: 0.5, isAnalysisStart: false)
        XCTAssertEqual(decision, .appendToCurrent)
    }

    /// A large gap (at or above the threshold) starts a new paragraph.
    func testLargeGapStartsNewParagraph() {
        var grouper = ParagraphGrouper()
        _ = grouper.decide(startSeconds: 0, durationSeconds: 1, isAnalysisStart: false) // ends at 1.0
        // Next segment starts at 3.0: a 2.0s gap, above threshold -> break.
        let decision = grouper.decide(startSeconds: 3.0, durationSeconds: 0.5, isAnalysisStart: false)
        XCTAssertEqual(decision, .newParagraph)
    }

    /// A gap exactly equal to the threshold breaks (the rule is `>=`).
    func testGapExactlyAtThresholdStartsNewParagraph() {
        var grouper = ParagraphGrouper(gapThreshold: 1.5)
        _ = grouper.decide(startSeconds: 0, durationSeconds: 1, isAnalysisStart: false) // ends at 1.0
        // Next starts at 2.5: exactly a 1.5s gap.
        let decision = grouper.decide(startSeconds: 2.5, durationSeconds: 0.5, isAnalysisStart: false)
        XCTAssertEqual(decision, .newParagraph)
    }

    /// An analysis start forces a new paragraph even when the raw gap would be small - a pause/resume
    /// seam is a deliberate break, and analysis time resets to ~0 so the gap would otherwise be bogus.
    func testAnalysisStartForcesNewParagraphDespiteSmallGap() {
        var grouper = ParagraphGrouper()
        _ = grouper.decide(startSeconds: 10.0, durationSeconds: 1, isAnalysisStart: false) // ends at 11.0
        // Resume: analysis time reset to ~0.1 (a tiny value), which against the prior 11.0 end would be
        // a large NEGATIVE gap. The analysis-start flag must force a break regardless.
        let decision = grouper.decide(startSeconds: 0.1, durationSeconds: 0.5, isAnalysisStart: true)
        XCTAssertEqual(decision, .newParagraph)
    }

    /// After an analysis-start break, the running end re-anchors at the new segment, so the FOLLOWING
    /// small-gap segment flows (the seam did not poison the gap math for subsequent segments).
    func testSegmentAfterAnalysisStartResumesNormalGapping() {
        var grouper = ParagraphGrouper()
        _ = grouper.decide(startSeconds: 10.0, durationSeconds: 1, isAnalysisStart: false)
        _ = grouper.decide(startSeconds: 0.0, durationSeconds: 1, isAnalysisStart: true) // seam, ends at 1.0
        // A small gap after the resume flows normally.
        let decision = grouper.decide(startSeconds: 1.3, durationSeconds: 0.5, isAnalysisStart: false)
        XCTAssertEqual(decision, .appendToCurrent)
    }

    /// A non-finite or negative duration is a degenerate range: it must yield a new paragraph rather
    /// than crash or propagate a bad number, and it resets the running anchor so the NEXT segment also
    /// starts fresh instead of measuring a gap against a non-finite end.
    func testNonFiniteOrNegativeDurationHandledAsNewParagraph() {
        var grouper = ParagraphGrouper()
        _ = grouper.decide(startSeconds: 0, durationSeconds: 1, isAnalysisStart: false)

        XCTAssertEqual(
            grouper.decide(startSeconds: 1.1, durationSeconds: .nan, isAnalysisStart: false),
            .newParagraph, "a NaN duration is a new paragraph")
        XCTAssertEqual(
            grouper.decide(startSeconds: 1.2, durationSeconds: .infinity, isAnalysisStart: false),
            .newParagraph, "an infinite duration is a new paragraph")
        XCTAssertEqual(
            grouper.decide(startSeconds: .nan, durationSeconds: 0.5, isAnalysisStart: false),
            .newParagraph, "a NaN start is a new paragraph")
        XCTAssertEqual(
            grouper.decide(startSeconds: 1.3, durationSeconds: -1, isAnalysisStart: false),
            .newParagraph, "a negative duration is a new paragraph")

        // After a degenerate range reset the anchor, a following small-gap segment still starts fresh
        // (there is no valid prior end to measure against), not a bogus append.
        XCTAssertEqual(
            grouper.decide(startSeconds: 5.0, durationSeconds: 1, isAnalysisStart: false),
            .newParagraph, "the segment after a degenerate range starts a fresh paragraph")
    }

    /// A realistic sequence: a first sentence spoken with a mid-thought breath stays one paragraph, a
    /// clear pause then breaks, and text flows again after it - exactly the Thoughts-style cadence.
    func testRealisticSequence() {
        var grouper = ParagraphGrouper()
        var decisions: [ParagraphGrouper.Decision] = []
        // "Remember to call the supplier" ends at 2.0.
        decisions.append(grouper.decide(startSeconds: 0.0, durationSeconds: 2.0, isAnalysisStart: false))
        // A breath: "before noon" starts at 2.5 (0.5s gap) -> same paragraph.
        decisions.append(grouper.decide(startSeconds: 2.5, durationSeconds: 1.0, isAnalysisStart: false)) // ends 3.5
        // A real pause: next thought starts at 6.0 (2.5s gap) -> new paragraph.
        decisions.append(grouper.decide(startSeconds: 6.0, durationSeconds: 1.5, isAnalysisStart: false)) // ends 7.5
        // Another breath: starts at 8.0 (0.5s gap) -> same paragraph.
        decisions.append(grouper.decide(startSeconds: 8.0, durationSeconds: 1.0, isAnalysisStart: false))

        XCTAssertEqual(decisions, [.newParagraph, .appendToCurrent, .newParagraph, .appendToCurrent])
    }

    /// The threshold is configurable so a device pass can tune it. A tighter threshold breaks on a gap
    /// the default would have flowed.
    func testCustomThresholdTightensBreaking() {
        var grouper = ParagraphGrouper(gapThreshold: 0.3)
        _ = grouper.decide(startSeconds: 0, durationSeconds: 1, isAnalysisStart: false) // ends at 1.0
        // A 0.4s gap: below the 1.5 default (would flow), but at/above the 0.3 custom threshold -> break.
        let decision = grouper.decide(startSeconds: 1.4, durationSeconds: 0.5, isAnalysisStart: false)
        XCTAssertEqual(decision, .newParagraph)
    }
}

/// Feedback 0012 (PR #24 review): the pure timing-merge helper used when segments merge into one
/// paragraph. All four (existing, incoming) combinations, so an append never silently degrades a real
/// range to text-only.
final class ParagraphTimingMergeTests: XCTestCase {
    func testBothNilMergesToNil() {
        XCTAssertNil(ParagraphTiming.merged(nil, nil))
    }

    func testExistingNilAdoptsIncoming() {
        let incoming = ParagraphTiming(start: 2.5, duration: 1.0)
        // The load-bearing case the first implementation dropped: a text-only paragraph that gains a
        // real recorded tail must ADOPT that tail's range, not stay text-only.
        XCTAssertEqual(ParagraphTiming.merged(nil, incoming), incoming)
    }

    func testIncomingNilKeepsExisting() {
        let existing = ParagraphTiming(start: 0.0, duration: 2.0)
        XCTAssertEqual(ParagraphTiming.merged(existing, nil), existing)
    }

    func testBothPresentSpanFirstStartThroughLastEnd() {
        let existing = ParagraphTiming(start: 0.0, duration: 2.0) // ends at 2.0
        let incoming = ParagraphTiming(start: 2.5, duration: 1.0) // ends at 3.5
        // One contiguous range: existing start (0.0) through incoming end (3.5).
        XCTAssertEqual(ParagraphTiming.merged(existing, incoming), ParagraphTiming(start: 0.0, duration: 3.5))
    }
}
