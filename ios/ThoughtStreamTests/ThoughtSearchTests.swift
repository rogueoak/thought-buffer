import XCTest
@testable import ThoughtStream

/// `ThoughtSearch` (spec 0021): the pure full-text match over the loaded thoughts. A thought matches when its
/// title OR any body paragraph contains the query, case-insensitive AND diacritic-insensitive, as a
/// substring; search is global across the whole folder tree and returns a flat, order-preserving list.
final class ThoughtSearchTests: XCTestCase {
    private func thought(
        _ title: String,
        _ paragraphs: [String],
        folder: [String] = [],
        epoch: TimeInterval = 0
    ) -> Thought {
        Thought(
            title: title,
            paragraphs: paragraphs,
            createdAt: Date(timeIntervalSince1970: epoch),
            folderPath: folder
        )
    }

    // MARK: - matches: title / body / substring

    func testMatchesOnTitle() {
        let n = thought("Grocery list", ["milk", "eggs"])
        XCTAssertTrue(ThoughtSearch.matches(n, query: "grocery"))
    }

    func testMatchesOnAnyBodyParagraph() {
        // The needle is only in the SECOND paragraph, not the title - spec 0021 is not title-only.
        let n = thought("Meeting", ["intro paragraph", "discuss the budget"])
        XCTAssertTrue(ThoughtSearch.matches(n, query: "budget"))
    }

    func testMatchesSubstringNotJustWholeWord() {
        let n = thought("Planning", ["schedule the review"])
        XCTAssertTrue(ThoughtSearch.matches(n, query: "plan"))
        XCTAssertTrue(ThoughtSearch.matches(n, query: "chedul"))
    }

    // MARK: - Case / diacritic insensitivity

    func testCaseInsensitive() {
        let n = thought("The Plan", ["Do The Thing"])
        XCTAssertTrue(ThoughtSearch.matches(n, query: "plan"))
        XCTAssertTrue(ThoughtSearch.matches(n, query: "PLAN"))
        XCTAssertTrue(ThoughtSearch.matches(n, query: "thing"))
    }

    func testDiacriticInsensitive() {
        // Query without accents finds a thought with accents, and vice versa.
        let accented = thought("Cafe visit", ["Meet at the caf\u{00E9}"]) // cafe with an accent in body
        XCTAssertTrue(ThoughtSearch.matches(accented, query: "cafe"))

        let plain = thought("resume", ["send the resume"])
        XCTAssertTrue(ThoughtSearch.matches(plain, query: "r\u{00E9}sum\u{00E9}")) // accented query, plain thought
    }

    // MARK: - No match

    func testNoMatch() {
        let n = thought("Grocery list", ["milk", "eggs"])
        XCTAssertFalse(ThoughtSearch.matches(n, query: "xyzzy"))
    }

    // MARK: - Empty / whitespace query

    func testEmptyQueryMatchesEverything() {
        let n = thought("anything", ["body"])
        XCTAssertTrue(ThoughtSearch.matches(n, query: ""))
        XCTAssertTrue(ThoughtSearch.matches(n, query: "   "))
    }

    func testIsActive() {
        XCTAssertFalse(ThoughtSearch.isActive(""))
        XCTAssertFalse(ThoughtSearch.isActive("   \n\t "))
        XCTAssertTrue(ThoughtSearch.isActive("a"))
        XCTAssertTrue(ThoughtSearch.isActive("  hello  "))
    }

    // MARK: - results: global across folders, order preserved

    func testResultsAreGlobalAcrossFolders() {
        let thoughts = [
            thought("root", ["find me here"], folder: [], epoch: 3_000),
            thought("work", ["nothing"], folder: ["Work"], epoch: 2_000),
            thought("deep", ["also find me"], folder: ["Work", "Q1"], epoch: 1_000),
        ]
        let results = ThoughtSearch.results(in: thoughts, query: "find me")
        XCTAssertEqual(results.map(\.title), ["root", "deep"])
    }

    func testResultsPreserveInputOrder() {
        // The store hands thoughts newest first; results must keep that order (no re-ranking, spec 0021).
        let thoughts = [
            thought("newest", ["alpha"], epoch: 3_000),
            thought("middle", ["alpha"], epoch: 2_000),
            thought("oldest", ["alpha"], epoch: 1_000),
        ]
        let results = ThoughtSearch.results(in: thoughts, query: "alpha")
        XCTAssertEqual(results.map(\.title), ["newest", "middle", "oldest"])
    }

    func testEmptyQueryReturnsAllUnchanged() {
        let thoughts = [thought("a", ["x"]), thought("b", ["y"])]
        XCTAssertEqual(ThoughtSearch.results(in: thoughts, query: "").map(\.title), ["a", "b"])
        XCTAssertEqual(ThoughtSearch.results(in: thoughts, query: "   ").map(\.title), ["a", "b"])
    }

    func testResultsNoMatchIsEmpty() {
        let thoughts = [thought("a", ["x"]), thought("b", ["y"])]
        XCTAssertTrue(ThoughtSearch.results(in: thoughts, query: "zzz").isEmpty)
    }
}
