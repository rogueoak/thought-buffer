import XCTest
@testable import ThoughtStream

/// `TranscriptCleanup.reflow` (spec 0016): merges obvious continuation lines (no terminal
/// punctuation before, lowercase start after), leaves deliberate breaks alone, never splits, and is
/// idempotent.
final class TranscriptCleanupTests: XCTestCase {

    func testMergesLowercaseContinuation() {
        // "the plan is" (no terminal punctuation) + "ready to go" (lowercase start) -> one paragraph.
        let input = ["the plan is", "ready to go"]
        XCTAssertEqual(TranscriptCleanup.reflow(input), ["the plan is ready to go"])
    }

    func testLeavesTerminatedSentenceAlone() {
        // The first paragraph ends in a period, so the second is a new sentence even if it is lowercase.
        let input = ["The plan is ready.", "then we ship"]
        XCTAssertEqual(TranscriptCleanup.reflow(input), ["The plan is ready.", "then we ship"])
    }

    func testLeavesCapitalizedNextAlone() {
        // No terminal punctuation on the first, but the second starts uppercase - a deliberate new
        // thought, not a continuation.
        let input = ["A first thought", "Another thought entirely"]
        XCTAssertEqual(TranscriptCleanup.reflow(input), input)
    }

    func testMergesRunOfContinuations() {
        let input = ["one piece", "of a longer", "sentence here"]
        XCTAssertEqual(TranscriptCleanup.reflow(input), ["one piece of a longer sentence here"])
    }

    func testMergesOnlyWhereBothSignalsAgree() {
        // Merge the first pair (lowercase continuation), keep the terminated boundary as a break.
        let input = ["a broken", "sentence.", "A new one starts"]
        XCTAssertEqual(TranscriptCleanup.reflow(input), ["a broken sentence.", "A new one starts"])
    }

    func testIsIdempotent() {
        let input = ["the plan is", "ready to go", "Then we ship."]
        let once = TranscriptCleanup.reflow(input)
        let twice = TranscriptCleanup.reflow(once)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(once, ["the plan is ready to go", "Then we ship."])
    }

    func testDropsEmptyEntriesWithoutMergingAcrossThem() {
        // A blank entry is dropped (paragraph arrays carry no empties), and it does not become a bridge
        // that merges the two real paragraphs around it - each is evaluated against its true predecessor.
        let input = ["A finished thought.", "   ", "Another finished thought."]
        XCTAssertEqual(
            TranscriptCleanup.reflow(input),
            ["A finished thought.", "Another finished thought."]
        )
    }

    func testNeverSplits() {
        // A single paragraph is returned as one paragraph, never broken apart.
        let input = ["one continuous paragraph with, some, commas and no breaks"]
        XCTAssertEqual(TranscriptCleanup.reflow(input), input)
    }

    func testEmptyInput() {
        XCTAssertEqual(TranscriptCleanup.reflow([]), [])
    }
}
