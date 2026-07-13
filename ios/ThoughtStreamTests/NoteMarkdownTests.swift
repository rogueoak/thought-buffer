import XCTest
@testable import ThoughtStream

/// Markdown (de)serialization: round-trip, paragraph split/join, title derivation, tolerance.
final class NoteMarkdownTests: XCTestCase {

    func testRoundTripPreservesFields() throws {
        let note = Note(
            id: UUID(),
            title: "Morning drive",
            paragraphs: ["First paragraph here.", "Second one, a bit longer than the first."],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let parsed = Note(markdown: note.markdown)

        XCTAssertEqual(parsed.id, note.id)
        XCTAssertEqual(parsed.title, note.title)
        XCTAssertEqual(parsed.paragraphs, note.paragraphs)
        // ISO-8601 with fractional seconds round-trips to within a millisecond.
        XCTAssertEqual(parsed.createdAt.timeIntervalSince1970,
                       note.createdAt.timeIntervalSince1970, accuracy: 0.01)
    }

    func testBodyJoinsParagraphsWithBlankLine() {
        let note = Note(
            title: "x",
            paragraphs: ["One.", "Two.", "Three."],
            createdAt: Date()
        )
        XCTAssertEqual(note.bodyMarkdown, "One.\n\nTwo.\n\nThree.")
    }

    func testSplitParagraphsOnBlankLines() {
        let body = "One paragraph.\n\nTwo paragraph.\n\n\nThree, extra blank line."
        let paragraphs = Note.splitParagraphs(body)
        XCTAssertEqual(paragraphs, ["One paragraph.", "Two paragraph.", "Three, extra blank line."])
    }

    func testBodyDropsEmptyParagraphs() {
        let note = Note(title: "x", paragraphs: ["Real.", "   ", "", "Also real."], createdAt: Date())
        XCTAssertEqual(note.bodyMarkdown, "Real.\n\nAlso real.")
    }

    func testTitleDerivedFromFirstLine() {
        let title = Note.deriveTitle(
            paragraphs: ["Call the supplier before noon.", "And then email."],
            createdAt: Date()
        )
        // Trailing period dropped.
        XCTAssertEqual(title, "Call the supplier before noon")
    }

    func testTitleFallbackWhenEmpty() {
        let title = Note.deriveTitle(paragraphs: [], createdAt: Date())
        XCTAssertTrue(title.hasPrefix("Note "), "expected dated fallback, got \(title)")
    }

    func testTolerantParseWithoutFrontmatter() {
        let text = "Just a body.\n\nWith two paragraphs."
        let note = Note(markdown: text)
        XCTAssertEqual(note.paragraphs, ["Just a body.", "With two paragraphs."])
        XCTAssertEqual(note.title, "Just a body")
    }

    func testUnknownFrontmatterKeysIgnored() {
        let id = UUID()
        let text = """
        ---
        id: \(id.uuidString)
        title: Kept
        futureField: some value we do not know yet
        created: 2023-11-14T22:13:20.000Z
        ---

        Body text.
        """
        let note = Note(markdown: text)
        XCTAssertEqual(note.id, id)
        XCTAssertEqual(note.title, "Kept")
        XCTAssertEqual(note.paragraphs, ["Body text."])
    }

    func testTitleWithColonIsQuotedAndRestored() throws {
        let note = Note(
            title: "Idea: travel tin",
            paragraphs: ["A travel tin, half the size."],
            createdAt: Date()
        )
        XCTAssertTrue(note.markdown.contains("title: \"Idea: travel tin\""))
        let parsed = Note(markdown: note.markdown)
        XCTAssertEqual(parsed.title, "Idea: travel tin")
    }
}
