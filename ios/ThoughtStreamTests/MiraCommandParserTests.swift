import XCTest
@testable import ThoughtStream

/// The Mira control-word parser: each command, reasonable phrasings, synonyms, case-insensitivity,
/// the required leading control word, and negatives that must not misfire.
final class MiraCommandParserTests: XCTestCase {
    private let parser = MiraCommandParser(controlWord: "Mira")

    // MARK: - Remove last sentence

    func testRemoveLastSentence() {
        XCTAssertEqual(parser.parse("Mira remove the last sentence"), .removeLastSentence)
        XCTAssertEqual(parser.parse("Mira remove last sentence"), .removeLastSentence)
        XCTAssertEqual(parser.parse("mira delete the last sentence"), .removeLastSentence)
        XCTAssertEqual(parser.parse("MIRA DELETE LAST SENTENCE"), .removeLastSentence)
        // Trailing comma / filler after the control word is tolerated.
        XCTAssertEqual(parser.parse("Mira, please remove the last sentence."), .removeLastSentence)
    }

    // MARK: - Remove last paragraph

    func testRemoveLastParagraph() {
        XCTAssertEqual(parser.parse("Mira remove the last paragraph"), .removeLastParagraph)
        XCTAssertEqual(parser.parse("Mira delete last paragraph"), .removeLastParagraph)
        XCTAssertEqual(parser.parse("mira remove the last paragraph."), .removeLastParagraph)
    }

    // MARK: - New note

    func testNewNote() {
        XCTAssertEqual(parser.parse("Mira new note"), .newNote)
        XCTAssertEqual(parser.parse("Mira start a new note"), .newNote)
        XCTAssertEqual(parser.parse("mira, new note"), .newNote)
    }

    // MARK: - Read that back

    func testReadThatBack() {
        XCTAssertEqual(parser.parse("Mira read that back"), .readThatBack)
        XCTAssertEqual(parser.parse("Mira read it back"), .readThatBack)
        XCTAssertEqual(parser.parse("Mira read back"), .readThatBack)
        XCTAssertEqual(parser.parse("mira read that back please"), .readThatBack)
    }

    // MARK: - Control word is required at the start

    func testControlWordRequiredAtStart() {
        // No control word at all.
        XCTAssertNil(parser.parse("remove the last sentence"))
        // Control word mid-sentence must not fire (ordinary speech mentioning Mira).
        XCTAssertNil(parser.parse("I asked Mira to remove the last sentence yesterday"))
        XCTAssertNil(parser.parse("tell Mira new note ideas later"))
    }

    // MARK: - Negatives: ordinary speech and unknown commands

    func testDoesNotMisfireOnOrdinarySpeech() {
        XCTAssertNil(parser.parse("The last sentence of the report was strong."))
        XCTAssertNil(parser.parse("Let's start a new paragraph about the budget."))
        XCTAssertNil(parser.parse("Read the last chapter before the meeting."))
    }

    func testControlWordAloneOrUnknownCommandReturnsNil() {
        XCTAssertNil(parser.parse("Mira"))
        XCTAssertNil(parser.parse("Mira how are you today"))
        // A bare mention of the name is committed as text, not dropped.
        XCTAssertNil(parser.parse("Mira is a lovely name"))
    }

    // MARK: - Injected control word

    func testCustomControlWord() {
        let custom = MiraCommandParser(controlWord: "Echo")
        XCTAssertEqual(custom.parse("Echo new note"), .newNote)
        XCTAssertNil(custom.parse("Mira new note"))
    }
}
