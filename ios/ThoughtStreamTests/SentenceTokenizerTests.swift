import XCTest
@testable import ThoughtStream

/// The sentence tokenizer used by "remove the last sentence".
final class SentenceTokenizerTests: XCTestCase {
    func testSplitsMultipleSentences() {
        let sentences = SentenceTokenizer.sentences(in: "Call the supplier. Draft the email. Ship it.")
        XCTAssertEqual(sentences.count, 3)
        XCTAssertEqual(sentences.first, "Call the supplier.")
        XCTAssertEqual(sentences.last, "Ship it.")
    }

    func testSingleSentenceWithoutPunctuation() {
        let sentences = SentenceTokenizer.sentences(in: "just one thought here")
        XCTAssertEqual(sentences, ["just one thought here"])
    }

    func testRemovingLastSentenceKeepsTheRest() {
        let result = SentenceTokenizer.removingLastSentence(
            from: "Call the supplier. Draft the email. Ship it."
        )
        XCTAssertEqual(result, "Call the supplier. Draft the email.")
    }

    func testRemovingLastSentenceFromSingleSentenceEmpties() {
        XCTAssertNil(SentenceTokenizer.removingLastSentence(from: "Only one sentence."))
    }

    func testRemovingLastSentenceFromEmptyIsNil() {
        XCTAssertNil(SentenceTokenizer.removingLastSentence(from: "   "))
    }
}
