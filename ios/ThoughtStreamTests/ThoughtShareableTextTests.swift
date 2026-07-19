import XCTest
@testable import ThoughtStream

/// `Thought.shareableText` (spec 0017): the plain-text form the detail page's Share sheet sends and the
/// Copy action puts on the pasteboard. Title line, a blank line, then paragraphs joined by blank
/// lines - across custom/derived titles and single/multi/empty bodies.
final class ThoughtShareableTextTests: XCTestCase {

    private let created = Date(timeIntervalSince1970: 1_700_000_000)

    func testCustomTitleSingleParagraph() {
        let thought = Thought(
            title: "Morning drive",
            paragraphs: ["Remember to call the plumber back."],
            createdAt: created,
            hasCustomTitle: true
        )

        XCTAssertEqual(
            thought.shareableText,
            "Morning drive\n\nRemember to call the plumber back."
        )
    }

    func testCustomTitleMultipleParagraphs() {
        let thought = Thought(
            title: "Groceries",
            paragraphs: ["Milk and eggs.", "Also coffee beans.", "Pick up the dry cleaning."],
            createdAt: created,
            hasCustomTitle: true
        )

        XCTAssertEqual(
            thought.shareableText,
            "Groceries\n\nMilk and eggs.\n\nAlso coffee beans.\n\nPick up the dry cleaning."
        )
    }

    func testDerivedTitleShares() {
        // A thought with no custom title still shares with its derived first-sentence title, and the
        // shared body is the full paragraph even though the title is only its first sentence.
        let paragraph = "Buy a new bike lock. The old one is rusted shut."
        let title = Thought.deriveTitle(paragraphs: [paragraph], createdAt: created)
        let thought = Thought(
            title: title,
            paragraphs: [paragraph],
            createdAt: created,
            hasCustomTitle: false
        )

        XCTAssertEqual(thought.title, "Buy a new bike lock")
        XCTAssertEqual(thought.shareableText, "Buy a new bike lock\n\n" + paragraph)
    }

    func testEmptyBodySharesTitleOnly() {
        // A title-only thought (no body paragraphs) shares just its title, with no trailing blank line.
        let thought = Thought(
            title: "Ideas",
            paragraphs: [],
            createdAt: created,
            hasCustomTitle: true
        )

        XCTAssertEqual(thought.shareableText, "Ideas")
    }

    func testWhitespaceOnlyParagraphsDropOutOfBody() {
        // Blank/whitespace-only paragraphs are dropped and real ones trimmed (mirrors bodyMarkdown),
        // so a thought whose only "body" is whitespace shares its title alone.
        let thought = Thought(
            title: "Blank",
            paragraphs: ["   ", "\n"],
            createdAt: created,
            hasCustomTitle: true
        )

        XCTAssertEqual(thought.shareableText, "Blank")
    }

    func testParagraphsAreTrimmed() {
        let thought = Thought(
            title: "Trim me",
            paragraphs: ["  leading and trailing spaces  ", "second"],
            createdAt: created,
            hasCustomTitle: true
        )

        XCTAssertEqual(
            thought.shareableText,
            "Trim me\n\nleading and trailing spaces\n\nsecond"
        )
    }
}
