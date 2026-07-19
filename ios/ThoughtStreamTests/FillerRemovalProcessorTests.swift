import XCTest
@testable import ThoughtStream

/// `FillerRemovalProcessor` (spec 0016): removes standalone hesitation tokens from committed
/// dictation text, tidies the spacing/punctuation/capitalization the removal leaves behind, drops a
/// segment that was nothing but fillers, and NEVER touches a filler that is part of a real word.
final class FillerRemovalProcessorTests: XCTestCase {
    private let processor = FillerRemovalProcessor()

    /// The `.text` result of processing, or a failure when the segment dropped or (impossibly) split.
    private func text(_ input: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard case .text(let out) = processor.process(input) else {
            XCTFail("expected .text for \(input)", file: file, line: line)
            return ""
        }
        return out
    }

    // MARK: - Removal in each position

    func testStripsLeadingFillerAndRecapitalizes() {
        // A leading filler removed -> the next word starts the sentence, so it is re-capitalized.
        XCTAssertEqual(text("um the plan"), "The plan")
        XCTAssertEqual(text("Uh, the plan"), "The plan")
    }

    func testStripsMidFiller() {
        XCTAssertEqual(text("So, um, yeah"), "So, yeah")
        // Leading "the" is not a filler, so casing stays verbatim; only the mid filler "uh" is stripped.
        XCTAssertEqual(text("the plan uh is ready"), "the plan is ready")
    }

    func testStripsTrailingFiller() {
        // Leading word is not a filler, so casing is left verbatim; only the trailing filler is stripped.
        XCTAssertEqual(text("that is the plan um"), "that is the plan")
        XCTAssertEqual(text("we ship today uh"), "we ship today")
    }

    func testStripsMultipleFillers() {
        // The spec's acceptance example: "um so, uh, the plan" -> "So, the plan".
        XCTAssertEqual(text("um so, uh, the plan"), "So, the plan")
    }

    func testCaseInsensitive() {
        XCTAssertEqual(text("UM the plan"), "The plan")
        XCTAssertEqual(text("Hmm the plan"), "The plan")
    }

    func testUhHuhIsOneToken() {
        // "uh-huh" is a single hyphenated filler token, removed whole.
        XCTAssertEqual(text("uh-huh the plan works"), "The plan works")
    }

    // MARK: - Empty segment drops (no empty paragraph, grouper not advanced)

    func testFillerOnlySegmentDrops() {
        XCTAssertEqual(processor.process("um"), .drop)
        XCTAssertEqual(processor.process("um uh erm"), .drop)
        XCTAssertEqual(processor.process("Um, uh... hmm."), .drop)
    }

    // MARK: - NEVER strip a filler inside a real word (false-positive guard)

    func testNeverAltersIAmHungry() {
        // "am" is not a filler and never a standalone default token, so the sentence is untouched.
        XCTAssertEqual(text("I am hungry"), "I am hungry")
    }

    func testNeverAltersAHummingbird() {
        // "um"/"hmm" are substrings of "hummingbird" but never a whole token in it. No filler was
        // removed, so the user's own casing (including the lowercase lead) is left verbatim.
        XCTAssertEqual(text("a hummingbird hummed"), "a hummingbird hummed")
    }

    func testNeverAltersWordsContainingFillerRuns() {
        // A spread of real words whose spelling contains a filler run: none is a standalone token, and
        // with nothing removed the casing is untouched.
        XCTAssertEqual(text("summer ahead, ermine, mummer, error"), "summer ahead, ermine, mummer, error")
    }

    func testDoesNotStripRiskyWords() {
        // The conservative default set excludes "like", "so", "you know", "yeah", "right".
        XCTAssertEqual(text("I like it, so yeah, right"), "I like it, so yeah, right")
    }

    // MARK: - Default set must never change factual content (engineer review)

    func testDoesNotStripMillimetreUnit() {
        // "mm"/"mmm" are removed from the DEFAULT set: "mm" is the millimetre unit, so stripping it
        // would turn "20 mm of rain" into "20 of rain" - a factual change. The default must leave it.
        XCTAssertEqual(text("20 mm of rain"), "20 mm of rain")
        XCTAssertEqual(text("5 mm"), "5 mm")
        XCTAssertEqual(text("the mmm setting"), "the mmm setting")
    }

    func testDoesNotStripErOrAhInterjections() {
        // "er"/"ah" are removed from the DEFAULT set: "Ah, finally!" is a genuine interjection and "er"
        // collides with real words, so the default leaves both. (Candidates for a future opt-in list.)
        XCTAssertEqual(text("Ah, finally!"), "Ah, finally!")
        XCTAssertEqual(text("er, maybe later"), "er, maybe later")
    }

    // MARK: - Quoted speech is left verbatim, and no removal leaves a broken artifact

    func testDoesNotStripFillerInsideQuotes() {
        // The user is transcribing someone's literal words: a filler inside a quoted span stays, and no
        // dangling comma is left hugging the open quote ("he said \"um, no\"" preserved verbatim).
        XCTAssertEqual(text("he said \"um, no\""), "he said \"um, no\"")
    }

    func testStripsFillerOutsideQuotesButNotInside() {
        // A leading (unquoted) filler is removed and the quoted content is untouched.
        XCTAssertEqual(text("um he said \"uh, sure\""), "He said \"uh, sure\"")
    }

    func testFillerRightAfterOpeningQuoteLeavesNoDanglingComma() {
        // Even in a MIXED case where a filler is removed adjacent to an opening quote, no stray comma is
        // left abutting the quote. Here the quote is unmatched (protects to end), so the inner "um" is
        // kept; the pass must still never produce a `", ` artifact hugging the quote.
        XCTAssertEqual(text("she quoted \"um, later"), "she quoted \"um, later")
    }

    // MARK: - Spacing / punctuation tidying

    func testCollapsesDanglingPunctuationAndSpaces() {
        XCTAssertEqual(text("Well um , done"), "Well, done")
        // Leading "first" is not a filler, so casing is left verbatim; only the spacing/commas tidy.
        XCTAssertEqual(text("first, um, um, second"), "first, second")
    }

    func testCollapsesSeparatorAbuttingTerminalMark() {
        // A filler between a comma and a terminal period must not leave a ",." artifact (engineer
        // review): "So, um. yeah" -> "So. yeah", not "So,. yeah".
        XCTAssertEqual(text("So, um. yeah"), "So. yeah")
    }

    // MARK: - Leading recapitalization does not corrupt an intentionally-cased brand

    func testLeadingRecapitalizationLeavesBrandCasingAlone() {
        // A promoted brand word ("iPhone") keeps its interior capital rather than becoming "IPhone".
        XCTAssertEqual(text("um iPhone stuff"), "iPhone stuff")
        XCTAssertEqual(text("uh eBay listing"), "eBay listing")
        // An ordinary all-lowercase lead is still fixed.
        XCTAssertEqual(text("um the plan"), "The plan")
    }

    // MARK: - Passthrough when nothing to remove

    func testLeavesCleanTextUnchanged() {
        XCTAssertEqual(text("The quick brown fox."), "The quick brown fox.")
    }
}
