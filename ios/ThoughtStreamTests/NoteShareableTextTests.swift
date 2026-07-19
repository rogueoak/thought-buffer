import XCTest
@testable import ThoughtStream

/// `Note.shareableText` (spec 0017): the plain-text form the detail page's Share sheet sends and the
/// Copy action puts on the pasteboard. Title line, a blank line, then paragraphs joined by blank
/// lines - across custom/derived titles and single/multi/empty bodies.
final class NoteShareableTextTests: XCTestCase {

    private let created = Date(timeIntervalSince1970: 1_700_000_000)

    func testCustomTitleSingleParagraph() {
        let note = Note(
            title: "Morning drive",
            paragraphs: ["Remember to call the plumber back."],
            createdAt: created,
            hasCustomTitle: true
        )

        XCTAssertEqual(
            note.shareableText,
            "Morning drive\n\nRemember to call the plumber back."
        )
    }

    func testCustomTitleMultipleParagraphs() {
        let note = Note(
            title: "Groceries",
            paragraphs: ["Milk and eggs.", "Also coffee beans.", "Pick up the dry cleaning."],
            createdAt: created,
            hasCustomTitle: true
        )

        XCTAssertEqual(
            note.shareableText,
            "Groceries\n\nMilk and eggs.\n\nAlso coffee beans.\n\nPick up the dry cleaning."
        )
    }

    func testDerivedTitleShares() {
        // A note with no custom title still shares with its derived first-sentence title, and the
        // shared body is the full paragraph even though the title is only its first sentence.
        let paragraph = "Buy a new bike lock. The old one is rusted shut."
        let title = Note.deriveTitle(paragraphs: [paragraph], createdAt: created)
        let note = Note(
            title: title,
            paragraphs: [paragraph],
            createdAt: created,
            hasCustomTitle: false
        )

        XCTAssertEqual(note.title, "Buy a new bike lock")
        XCTAssertEqual(note.shareableText, "Buy a new bike lock\n\n" + paragraph)
    }

    func testEmptyBodySharesTitleOnly() {
        // A title-only note (no body paragraphs) shares just its title, with no trailing blank line.
        let note = Note(
            title: "Ideas",
            paragraphs: [],
            createdAt: created,
            hasCustomTitle: true
        )

        XCTAssertEqual(note.shareableText, "Ideas")
    }

    func testWhitespaceOnlyParagraphsDropOutOfBody() {
        // Blank/whitespace-only paragraphs are dropped and real ones trimmed (mirrors bodyMarkdown),
        // so a note whose only "body" is whitespace shares its title alone.
        let note = Note(
            title: "Blank",
            paragraphs: ["   ", "\n"],
            createdAt: created,
            hasCustomTitle: true
        )

        XCTAssertEqual(note.shareableText, "Blank")
    }

    func testParagraphsAreTrimmed() {
        let note = Note(
            title: "Trim me",
            paragraphs: ["  leading and trailing spaces  ", "second"],
            createdAt: created,
            hasCustomTitle: true
        )

        XCTAssertEqual(
            note.shareableText,
            "Trim me\n\nleading and trailing spaces\n\nsecond"
        )
    }
}
