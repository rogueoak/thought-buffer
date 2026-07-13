import XCTest
@testable import ThoughtStream

/// `SpellingOverrideProcessor`: whole-word, case-insensitive replacement of dictated text, with
/// multiple overrides and no substring corruption.
final class SpellingOverrideProcessorTests: XCTestCase {
    private func processed(_ text: String, _ overrides: [SpellingOverride]) -> String {
        let processor = SpellingOverrideProcessor(overrides: overrides)
        guard case .text(let out) = processor.process(text) else {
            XCTFail("expected .text")
            return ""
        }
        return out
    }

    func testAlwaysReturnsText() {
        let processor = SpellingOverrideProcessor(overrides: [])
        XCTAssertEqual(processor.process("anything at all"), .text("anything at all"))
    }

    func testBasicReplacement() {
        let result = processed("Call about the Shay order", [SpellingOverride(from: "Shay", to: "Shea")])
        XCTAssertEqual(result, "Call about the Shea order")
    }

    func testCaseInsensitiveMatch() {
        let overrides = [SpellingOverride(from: "Shay", to: "Shea")]
        XCTAssertEqual(processed("shay is here", overrides), "Shea is here")
        XCTAssertEqual(processed("SHAY is loud", overrides), "Shea is loud")
        XCTAssertEqual(processed("ShAy again", overrides), "Shea again")
    }

    func testPreservesReplacementCasing() {
        // The `to` casing is written verbatim, regardless of how `from` was spoken.
        let result = processed("hello nyc please", [SpellingOverride(from: "nyc", to: "NYC")])
        XCTAssertEqual(result, "hello NYC please")
    }

    func testWholeWordOnlyNoSubstringCorruption() {
        let overrides = [SpellingOverride(from: "Shay", to: "Shea")]
        // "Shayla" contains "shay" but is a different word: it must be untouched.
        XCTAssertEqual(processed("Shayla went home", overrides), "Shayla went home")
        // "ashaya" contains "shay" in the middle: untouched.
        XCTAssertEqual(processed("the ashaya plant", overrides), "the ashaya plant")
    }

    func testMultipleOverridesTogether() {
        let overrides = [
            SpellingOverride(from: "Shay", to: "Shea"),
            SpellingOverride(from: "kwan", to: "Quan"),
        ]
        XCTAssertEqual(
            processed("Shay and kwan met", overrides),
            "Shea and Quan met"
        )
    }

    func testMultipleOccurrencesOfSameWord() {
        let overrides = [SpellingOverride(from: "Shay", to: "Shea")]
        XCTAssertEqual(processed("Shay, oh Shay, dear Shay", overrides), "Shea, oh Shea, dear Shea")
    }

    func testPunctuationAndSpacingPreserved() {
        let overrides = [SpellingOverride(from: "Shay", to: "Shea")]
        XCTAssertEqual(processed("Hi, Shay! How are you?", overrides), "Hi, Shea! How are you?")
    }

    func testBlankFromIsIgnored() {
        // A half-typed override (blank `from`) must not replace or corrupt anything.
        let overrides = [SpellingOverride(from: "  ", to: "X")]
        XCTAssertEqual(processed("nothing changes here", overrides), "nothing changes here")
    }

    func testBlankToIsIgnoredAndDoesNotDelete() {
        // A half-typed override (blank `to`) must NOT delete the spoken word - a blank replacement
        // would be a silent deletion, the opposite of a spelling fix. The row is inert until both
        // sides are filled. The Settings "Add override" flow persists exactly this empty state.
        XCTAssertEqual(processed("call Shay today", [SpellingOverride(from: "Shay", to: "")]), "call Shay today")
        XCTAssertEqual(processed("call Shay today", [SpellingOverride(from: "Shay", to: "  ")]), "call Shay today")
    }

    func testMultiWordFromNeverMatches() {
        // The tokenizer is whole-word (`\w+`), so a `from` containing a space (or other non-word
        // character) can never match a single token: it is inert rather than partially replacing.
        // This pins the known limit - multi-word overrides are out of scope for this milestone.
        let overrides = [SpellingOverride(from: "new york", to: "NYC")]
        XCTAssertEqual(processed("moved to new york city", overrides), "moved to new york city")
    }

    func testFirstOverrideWinsOnDuplicateFrom() {
        let overrides = [
            SpellingOverride(from: "sea", to: "see"),
            SpellingOverride(from: "SEA", to: "C"),
        ]
        XCTAssertEqual(processed("by the sea", overrides), "by the see")
    }
}
