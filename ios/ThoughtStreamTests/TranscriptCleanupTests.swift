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

    // MARK: - refinedForSave gating (the single enforcement of "on edit-save when on, not on load")

    /// A thought whose paragraphs WOULD reflow (lowercase continuation), so the gating is observable.
    private func reflowableThought() -> Thought {
        Thought(
            title: "My title",
            paragraphs: ["the plan is", "ready to go"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            hasCustomTitle: true
        )
    }

    func testRefinedForSaveOffReturnsThoughtVerbatim() {
        // refine OFF: the thought is returned unchanged even though it WOULD reflow.
        let thought = reflowableThought()
        let result = TranscriptCleanup.refinedForSave(thought, refine: false)
        XCTAssertEqual(result.paragraphs, ["the plan is", "ready to go"])
        XCTAssertEqual(result.id, thought.id)
    }

    func testRefinedForSaveOnMergesReflowableThought() {
        // refine ON, commit-edit path: the reflowable thought is saved MERGED, preserving id/title/custom.
        let thought = reflowableThought()
        let result = TranscriptCleanup.refinedForSave(thought, refine: true)
        XCTAssertEqual(result.paragraphs, ["the plan is ready to go"])
        XCTAssertEqual(result.id, thought.id)
        XCTAssertEqual(result.title, "My title")
        XCTAssertTrue(result.hasCustomTitle)
    }

    func testRefinedForSaveOnLeavesNonReflowableThoughtUnchanged() {
        // refine ON but nothing to merge (terminated sentences): the thought is returned as-is.
        let thought = Thought(
            title: "T",
            paragraphs: ["A finished thought.", "Another finished thought."],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let result = TranscriptCleanup.refinedForSave(thought, refine: true)
        XCTAssertEqual(result.paragraphs, ["A finished thought.", "Another finished thought."])
    }
}
