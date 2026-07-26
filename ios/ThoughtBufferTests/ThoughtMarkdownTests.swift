import XCTest
@testable import ThoughtBuffer

/// Markdown (de)serialization: round-trip, paragraph split/join, title derivation, tolerance.
final class ThoughtMarkdownTests: XCTestCase {

    func testRoundTripPreservesFields() throws {
        let thought = Thought(
            id: UUID(),
            title: "Morning drive",
            paragraphs: ["First paragraph here.", "Second one, a bit longer than the first."],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let parsed = Thought(markdown: thought.markdown)

        XCTAssertEqual(parsed.id, thought.id)
        XCTAssertEqual(parsed.title, thought.title)
        XCTAssertEqual(parsed.paragraphs, thought.paragraphs)
        // ISO-8601 with fractional seconds round-trips to within a millisecond.
        XCTAssertEqual(parsed.createdAt.timeIntervalSince1970,
                       thought.createdAt.timeIntervalSince1970, accuracy: 0.01)
    }

    func testBodyJoinsParagraphsWithBlankLine() {
        let thought = Thought(
            title: "x",
            paragraphs: ["One.", "Two.", "Three."],
            createdAt: Date()
        )
        XCTAssertEqual(thought.bodyMarkdown, "One.\n\nTwo.\n\nThree.")
    }

    func testSplitParagraphsOnBlankLines() {
        let body = "One paragraph.\n\nTwo paragraph.\n\n\nThree, extra blank line."
        let paragraphs = Thought.splitParagraphs(body)
        XCTAssertEqual(paragraphs, ["One paragraph.", "Two paragraph.", "Three, extra blank line."])
    }

    func testBodyDropsEmptyParagraphs() {
        let thought = Thought(title: "x", paragraphs: ["Real.", "   ", "", "Also real."], createdAt: Date())
        XCTAssertEqual(thought.bodyMarkdown, "Real.\n\nAlso real.")
    }

    func testTitleDerivedFromFirstSentence() {
        let title = Thought.deriveTitle(
            paragraphs: ["Call the supplier before noon.", "And then email."],
            createdAt: Date()
        )
        // Trailing period dropped; a single-sentence first paragraph is used whole.
        XCTAssertEqual(title, "Call the supplier before noon")
    }

    func testTitleIsOnlyTheFirstSentenceOfTheFirstParagraph() {
        // Spec 0009: the title is the first sentence (up to the first pause), not the whole first
        // line, so a multi-sentence opening paragraph yields just its opening sentence.
        let title = Thought.deriveTitle(
            paragraphs: ["Hello there. This part should not be in the title.", "More."],
            createdAt: Date()
        )
        XCTAssertEqual(title, "Hello there")
    }

    func testCustomTitleRoundTrips() {
        let thought = Thought(
            title: "Q3 planning offsite",
            paragraphs: ["We talked about the roadmap and hiring."],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            hasCustomTitle: true
        )
        XCTAssertTrue(thought.markdown.contains("titleCustom: true"))
        let parsed = Thought(markdown: thought.markdown)
        XCTAssertTrue(parsed.hasCustomTitle)
        XCTAssertEqual(parsed.title, "Q3 planning offsite")
    }

    func testDerivedTitleWritesNoCustomFlag() {
        // A non-custom thought serializes exactly as before - no titleCustom key - and parses back to
        // false, so old files (which never had the key) load as non-custom.
        let thought = Thought(
            title: "Anything",
            paragraphs: ["A body."],
            createdAt: Date()
        )
        XCTAssertFalse(thought.markdown.contains("titleCustom"))
        XCTAssertFalse(Thought(markdown: thought.markdown).hasCustomTitle)
    }

    func testCustomTitleWithColonRoundTripsWithFlag() {
        // A user title with YAML-tricky characters must round-trip together with titleCustom (the
        // acceptance pairs escaping with the custom flag; the existing colon test is non-custom).
        let thought = Thought(
            title: "Meeting: Q3 \"offsite\"",
            paragraphs: ["Thoughts body."],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            hasCustomTitle: true
        )
        let parsed = Thought(markdown: thought.markdown)
        XCTAssertTrue(parsed.hasCustomTitle)
        XCTAssertEqual(parsed.title, "Meeting: Q3 \"offsite\"")
    }

    func testResolveTitleEditEmptyResetsToDerived() {
        let resolved = Thought.resolveTitleEdit(
            rawTitle: "   ",
            paragraphs: ["The first sentence. And more."],
            createdAt: Date()
        )
        XCTAssertFalse(resolved.isCustom)
        XCTAssertEqual(resolved.title, "The first sentence")
    }

    func testResolveTitleEditNonEmptySetsCustom() {
        let resolved = Thought.resolveTitleEdit(
            rawTitle: "  My chosen title  ",
            paragraphs: ["Body sentence."],
            createdAt: Date()
        )
        XCTAssertTrue(resolved.isCustom)
        XCTAssertEqual(resolved.title, "My chosen title")
    }

    func testStrayCustomFlagWithoutStoredTitleIsNotCustom() {
        // Guard: titleCustom only owns a STORED title. With no title line, the thought derives and stays
        // non-custom so a half-written/future file never marks a derived title as user-set.
        let text = """
        ---
        titleCustom: true
        ---

        Derived body sentence.
        """
        let thought = Thought(markdown: text)
        XCTAssertFalse(thought.hasCustomTitle)
        XCTAssertEqual(thought.title, "Derived body sentence")
    }

    func testTitleFallbackWhenEmpty() {
        let title = Thought.deriveTitle(paragraphs: [], createdAt: Date())
        XCTAssertTrue(title.hasPrefix("Thought "), "expected dated fallback, got \(title)")
    }

    // MARK: isBlankDraft (spec 0013)

    func testIsBlankDraftEmptyIsBlank() {
        XCTAssertTrue(Thought.isBlankDraft(paragraphs: [], hasCustomTitle: false, customTitle: ""))
    }

    func testIsBlankDraftWhitespaceOnlyBodyIsBlank() {
        XCTAssertTrue(Thought.isBlankDraft(
            paragraphs: ["   ", "\n\t"],
            hasCustomTitle: false,
            customTitle: ""
        ))
    }

    func testIsBlankDraftTitleOnlyIsNotBlank() {
        // A user-entered custom title with no body is real content: keep, do not discard.
        XCTAssertFalse(Thought.isBlankDraft(
            paragraphs: [],
            hasCustomTitle: true,
            customTitle: "My chosen title"
        ))
    }

    func testIsBlankDraftBodyOnlyIsNotBlank() {
        XCTAssertFalse(Thought.isBlankDraft(
            paragraphs: ["Some typed thought."],
            hasCustomTitle: false,
            customTitle: ""
        ))
    }

    func testIsBlankDraftDerivedTitleWithEmptyBodyIsBlank() {
        // A non-custom (derived) title is synthesized from the body, so it is not content on its own.
        XCTAssertTrue(Thought.isBlankDraft(
            paragraphs: [],
            hasCustomTitle: false,
            customTitle: "A derived first sentence"
        ))
    }

    func testIsBlankDraftWhitespaceOnlyCustomTitleIsBlank() {
        XCTAssertTrue(Thought.isBlankDraft(
            paragraphs: [],
            hasCustomTitle: true,
            customTitle: "   "
        ))
    }

    // MARK: editedCopy preserves folder + recording (spec 0013 / folders regression)

    func testEditedCopyKeepsFolderPath() {
        // Regression: rebuilding a thought on edit must preserve its storage location. Without this,
        // ThoughtStore.save (which files by folderPath) would relocate a foldered thought to the root on
        // every commit.
        let original = Thought(
            title: "Original",
            paragraphs: ["First body."],
            createdAt: Date(),
            folderPath: ["Work"]
        )
        let edited = original.editedCopy(
            paragraphs: ["First body.", "A new second paragraph."],
            hasCustomTitle: false,
            customTitle: "Original"
        )
        XCTAssertEqual(edited.folderPath, ["Work"])
        XCTAssertEqual(edited.paragraphs, ["First body.", "A new second paragraph."])
        XCTAssertEqual(edited.id, original.id)
    }

    func testEditedCopyKeepsNestedFolderAndCapsTimings() {
        let original = Thought(
            id: UUID(),
            title: "Recorded",
            paragraphs: ["One.", "Two."],
            createdAt: Date(),
            audioFileName: "abc.m4a",
            timings: [ParagraphTiming(start: 0, duration: 1), ParagraphTiming(start: 1, duration: 1)],
            folderPath: ["Work", "Q3"]
        )
        // An edit that shrinks the body to one paragraph must keep the nested folder and cap timings.
        let edited = original.editedCopy(
            paragraphs: ["One."],
            hasCustomTitle: false,
            customTitle: "Recorded"
        )
        XCTAssertEqual(edited.folderPath, ["Work", "Q3"])
        XCTAssertEqual(edited.audioFileName, "abc.m4a")
        XCTAssertEqual(edited.timings.count, 1)
    }

    func testTolerantParseWithoutFrontmatter() {
        let text = "Just a body.\n\nWith two paragraphs."
        let thought = Thought(markdown: text)
        XCTAssertEqual(thought.paragraphs, ["Just a body.", "With two paragraphs."])
        XCTAssertEqual(thought.title, "Just a body")
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
        let thought = Thought(markdown: text)
        XCTAssertEqual(thought.id, id)
        XCTAssertEqual(thought.title, "Kept")
        XCTAssertEqual(thought.paragraphs, ["Body text."])
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
            XCTAssertEqual(Thought.sanitizedFolderName(input), "",
                           "expected \(input.debugDescription) to be rejected")
        }
    }

    /// A control character embedded anywhere in the name (not just leading) is rejected.
    func testSanitizedFolderNameRejectsEmbeddedControlCharacter() {
        XCTAssertEqual(Thought.sanitizedFolderName("Wo\u{0000}rk"), "")
        XCTAssertEqual(Thought.sanitizedFolderName("Line\nBreak"), "")
    }

    /// A normal name is accepted UNCHANGED (only surrounding whitespace is trimmed) and round-trips.
    func testSanitizedFolderNameAcceptsNormalNamesUnchanged() {
        XCTAssertEqual(Thought.sanitizedFolderName("Work"), "Work")
        XCTAssertEqual(Thought.sanitizedFolderName("Book ideas"), "Book ideas")
        // Surrounding whitespace is trimmed but the interior is preserved verbatim.
        XCTAssertEqual(Thought.sanitizedFolderName("  Book ideas  "), "Book ideas")
        // Round-trip: an accepted name sanitizes to itself.
        let accepted = "Book ideas"
        XCTAssertEqual(Thought.sanitizedFolderName(accepted), accepted)
    }

    func testTitleWithColonIsQuotedAndRestored() throws {
        let thought = Thought(
            title: "Idea: travel tin",
            paragraphs: ["A travel tin, half the size."],
            createdAt: Date()
        )
        XCTAssertTrue(thought.markdown.contains("title: \"Idea: travel tin\""))
        let parsed = Thought(markdown: thought.markdown)
        XCTAssertEqual(parsed.title, "Idea: travel tin")
    }
}
