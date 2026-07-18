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

    func testTitleDerivedFromFirstSentence() {
        let title = Note.deriveTitle(
            paragraphs: ["Call the supplier before noon.", "And then email."],
            createdAt: Date()
        )
        // Trailing period dropped; a single-sentence first paragraph is used whole.
        XCTAssertEqual(title, "Call the supplier before noon")
    }

    func testTitleIsOnlyTheFirstSentenceOfTheFirstParagraph() {
        // Spec 0009: the title is the first sentence (up to the first pause), not the whole first
        // line, so a multi-sentence opening paragraph yields just its opening sentence.
        let title = Note.deriveTitle(
            paragraphs: ["Hello there. This part should not be in the title.", "More."],
            createdAt: Date()
        )
        XCTAssertEqual(title, "Hello there")
    }

    func testCustomTitleRoundTrips() {
        let note = Note(
            title: "Q3 planning offsite",
            paragraphs: ["We talked about the roadmap and hiring."],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            hasCustomTitle: true
        )
        XCTAssertTrue(note.markdown.contains("titleCustom: true"))
        let parsed = Note(markdown: note.markdown)
        XCTAssertTrue(parsed.hasCustomTitle)
        XCTAssertEqual(parsed.title, "Q3 planning offsite")
    }

    func testDerivedTitleWritesNoCustomFlag() {
        // A non-custom note serializes exactly as before - no titleCustom key - and parses back to
        // false, so old files (which never had the key) load as non-custom.
        let note = Note(
            title: "Anything",
            paragraphs: ["A body."],
            createdAt: Date()
        )
        XCTAssertFalse(note.markdown.contains("titleCustom"))
        XCTAssertFalse(Note(markdown: note.markdown).hasCustomTitle)
    }

    func testCustomTitleWithColonRoundTripsWithFlag() {
        // A user title with YAML-tricky characters must round-trip together with titleCustom (the
        // acceptance pairs escaping with the custom flag; the existing colon test is non-custom).
        let note = Note(
            title: "Meeting: Q3 \"offsite\"",
            paragraphs: ["Notes body."],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            hasCustomTitle: true
        )
        let parsed = Note(markdown: note.markdown)
        XCTAssertTrue(parsed.hasCustomTitle)
        XCTAssertEqual(parsed.title, "Meeting: Q3 \"offsite\"")
    }

    func testResolveTitleEditEmptyResetsToDerived() {
        let resolved = Note.resolveTitleEdit(
            rawTitle: "   ",
            paragraphs: ["The first sentence. And more."],
            createdAt: Date()
        )
        XCTAssertFalse(resolved.isCustom)
        XCTAssertEqual(resolved.title, "The first sentence")
    }

    func testResolveTitleEditNonEmptySetsCustom() {
        let resolved = Note.resolveTitleEdit(
            rawTitle: "  My chosen title  ",
            paragraphs: ["Body sentence."],
            createdAt: Date()
        )
        XCTAssertTrue(resolved.isCustom)
        XCTAssertEqual(resolved.title, "My chosen title")
    }

    func testStrayCustomFlagWithoutStoredTitleIsNotCustom() {
        // Guard: titleCustom only owns a STORED title. With no title line, the note derives and stays
        // non-custom so a half-written/future file never marks a derived title as user-set.
        let text = """
        ---
        titleCustom: true
        ---

        Derived body sentence.
        """
        let note = Note(markdown: text)
        XCTAssertFalse(note.hasCustomTitle)
        XCTAssertEqual(note.title, "Derived body sentence")
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

    // MARK: - Folder name sanitizer (spec 0010, reject-not-strip)

    /// The sanitizer REJECTS unsafe names whole rather than stripping characters out of them, so it
    /// can never synthesize a traversal from otherwise-inert input (e.g. "..\t.." would collapse to
    /// ".." under a stripping sanitizer). Each adversarial input returns "" (rejected).
    func testSanitizedFolderNameRejectsAdversarialInputs() {
        let rejected = [
            "..\t..",       // tab between dots: a stripper would collapse to ".."
            ". .",          // dots with a space
            ". . .",
            "..",           // parent escape
            ".",            // self
            "/",            // bare separator
            "a/b",          // embedded forward separator
            "a\\b",         // embedded backslash
            ".hidden",      // leading dot -> hidden dir, undiscoverable by loadAll
            "a:b",          // drive/volume separator
            "\u{0007}bell", // control character
            "   ",          // whitespace only -> empty after trim
            "",             // empty
        ]
        for input in rejected {
            XCTAssertEqual(Note.sanitizedFolderName(input), "",
                           "expected \(input.debugDescription) to be rejected")
        }
    }

    /// A control character embedded anywhere in the name (not just leading) is rejected.
    func testSanitizedFolderNameRejectsEmbeddedControlCharacter() {
        XCTAssertEqual(Note.sanitizedFolderName("Wo\u{0000}rk"), "")
        XCTAssertEqual(Note.sanitizedFolderName("Line\nBreak"), "")
    }

    /// A normal name is accepted UNCHANGED (only surrounding whitespace is trimmed) and round-trips.
    func testSanitizedFolderNameAcceptsNormalNamesUnchanged() {
        XCTAssertEqual(Note.sanitizedFolderName("Work"), "Work")
        XCTAssertEqual(Note.sanitizedFolderName("Book ideas"), "Book ideas")
        // Surrounding whitespace is trimmed but the interior is preserved verbatim.
        XCTAssertEqual(Note.sanitizedFolderName("  Book ideas  "), "Book ideas")
        // Round-trip: an accepted name sanitizes to itself.
        let accepted = "Book ideas"
        XCTAssertEqual(Note.sanitizedFolderName(accepted), accepted)
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
