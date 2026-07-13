import XCTest
@testable import ThoughtStream

/// The Mira control-word parser (feedback 0005 model): each command, tolerant filler, synonyms,
/// case-insensitivity, the required LEADING control word, keyword-led-gibberish dropping as an
/// unrecognized command, and non-keyword-led speech committing as text.
final class MiraCommandParserTests: XCTestCase {
    private let parser = MiraCommandParser(controlWord: "Mira")

    // MARK: - Remove last sentence

    func testRemoveLastSentence() {
        XCTAssertEqual(parser.parse("Mira remove the last sentence"), .command(.removeLastSentence))
        XCTAssertEqual(parser.parse("Mira remove last sentence"), .command(.removeLastSentence))
        XCTAssertEqual(parser.parse("mira delete the last sentence"), .command(.removeLastSentence))
        XCTAssertEqual(parser.parse("MIRA DELETE LAST SENTENCE"), .command(.removeLastSentence))
        // Trailing comma / filler after the control word is tolerated.
        XCTAssertEqual(parser.parse("Mira, please remove the last sentence."), .command(.removeLastSentence))
    }

    // MARK: - Remove last paragraph

    func testRemoveLastParagraph() {
        XCTAssertEqual(parser.parse("Mira remove the last paragraph"), .command(.removeLastParagraph))
        XCTAssertEqual(parser.parse("Mira delete last paragraph"), .command(.removeLastParagraph))
        XCTAssertEqual(parser.parse("mira remove the last paragraph."), .command(.removeLastParagraph))
    }

    // MARK: - New note

    func testNewNote() {
        XCTAssertEqual(parser.parse("Mira new note"), .command(.newNote))
        XCTAssertEqual(parser.parse("Mira start a new note"), .command(.newNote))
        XCTAssertEqual(parser.parse("mira, new note"), .command(.newNote))
    }

    // MARK: - Read that back (including tolerant trailing filler "to me" - feedback 0005)

    func testReadThatBack() {
        XCTAssertEqual(parser.parse("Mira read that back"), .command(.readThatBack))
        XCTAssertEqual(parser.parse("Mira read it back"), .command(.readThatBack))
        XCTAssertEqual(parser.parse("Mira read back"), .command(.readThatBack))
        XCTAssertEqual(parser.parse("mira read that back please"), .command(.readThatBack))
    }

    /// The reported phrase: trailing "to me" / "for me" filler must NOT block the match anymore.
    func testReadThatBackWithTrailingFiller() {
        XCTAssertEqual(parser.parse("Mira read that back to me"), .command(.readThatBack))
        XCTAssertEqual(parser.parse("Mira read it back for me"), .command(.readThatBack))
        XCTAssertEqual(parser.parse("Mira, please read that back to me."), .command(.readThatBack))
    }

    // MARK: - Non-keyword-led speech is TEXT (transcribed as normal)

    func testNonKeywordLedSpeechIsText() {
        XCTAssertEqual(parser.parse("remove the last sentence"), .text)
        // A mid-sentence mention of the control word is ordinary speech, still transcribed.
        XCTAssertEqual(parser.parse("I asked Mira to remove the last sentence yesterday"), .text)
        XCTAssertEqual(parser.parse("The last sentence of the report was strong."), .text)
        XCTAssertEqual(parser.parse("Let's start a new paragraph about the budget."), .text)
    }

    // MARK: - Keyword-led but NOT a known command -> dropped (unrecognized command), NOT transcribed

    /// Feedback 0005: anything that LEADS with the control word is command mode. If it is not a
    /// known command it is DROPPED (the view model shows a chip), never transcribed. This
    /// supersedes the old strict-match design that committed these as text.
    func testKeywordLedGibberishIsUnrecognizedCommand() {
        XCTAssertEqual(parser.parse("Mira"), .unrecognizedCommand)
        XCTAssertEqual(parser.parse("Mira how are you today"), .unrecognizedCommand)
        XCTAssertEqual(parser.parse("Mira is a lovely name"), .unrecognizedCommand)
        XCTAssertEqual(parser.parse("Mira, there's a new note from Karen"), .unrecognizedCommand)
        XCTAssertEqual(parser.parse("Mira read that note back to the team"), .unrecognizedCommand)
        XCTAssertEqual(parser.parse("Mira remove the last sentence from the report about sales"), .unrecognizedCommand)
        XCTAssertEqual(parser.parse("Mira flibbertigibbet wooza"), .unrecognizedCommand)
    }

    // MARK: - Injected control word

    func testCustomControlWord() {
        let custom = MiraCommandParser(controlWord: "Echo")
        XCTAssertEqual(custom.parse("Echo new note"), .command(.newNote))
        // A different control word leads: command mode, but no match -> dropped, not text.
        XCTAssertEqual(custom.parse("Echo blah blah"), .unrecognizedCommand)
        // "Mira" is no longer the control word, so a Mira-led phrase is ordinary text.
        XCTAssertEqual(custom.parse("Mira new note"), .text)
    }

    // MARK: - command(in:) convenience

    func testCommandConvenience() {
        XCTAssertEqual(parser.command(in: "Mira new note"), .newNote)
        XCTAssertNil(parser.command(in: "Mira gibberish"))
        XCTAssertNil(parser.command(in: "an ordinary sentence"))
    }
}
