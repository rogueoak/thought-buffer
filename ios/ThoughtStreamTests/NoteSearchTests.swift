import XCTest
@testable import ThoughtStream

/// `NoteSearch` (spec 0021): the pure full-text match over the loaded notes. A note matches when its
/// title OR any body paragraph contains the query, case-insensitive AND diacritic-insensitive, as a
/// substring; search is global across the whole folder tree and returns a flat, order-preserving list.
final class NoteSearchTests: XCTestCase {
    private func note(
        _ title: String,
        _ paragraphs: [String],
        folder: [String] = [],
        epoch: TimeInterval = 0
    ) -> Note {
        Note(
            title: title,
            paragraphs: paragraphs,
            createdAt: Date(timeIntervalSince1970: epoch),
            folderPath: folder
        )
    }

    // MARK: - matches: title / body / substring

    func testMatchesOnTitle() {
        let n = note("Grocery list", ["milk", "eggs"])
        XCTAssertTrue(NoteSearch.matches(n, query: "grocery"))
    }

    func testMatchesOnAnyBodyParagraph() {
        // The needle is only in the SECOND paragraph, not the title - spec 0021 is not title-only.
        let n = note("Meeting", ["intro paragraph", "discuss the budget"])
        XCTAssertTrue(NoteSearch.matches(n, query: "budget"))
    }

    func testMatchesSubstringNotJustWholeWord() {
        let n = note("Planning", ["schedule the review"])
        XCTAssertTrue(NoteSearch.matches(n, query: "plan"))
        XCTAssertTrue(NoteSearch.matches(n, query: "chedul"))
    }

    // MARK: - Case / diacritic insensitivity

    func testCaseInsensitive() {
        let n = note("The Plan", ["Do The Thing"])
        XCTAssertTrue(NoteSearch.matches(n, query: "plan"))
        XCTAssertTrue(NoteSearch.matches(n, query: "PLAN"))
        XCTAssertTrue(NoteSearch.matches(n, query: "thing"))
    }

    func testDiacriticInsensitive() {
        // Query without accents finds a note with accents, and vice versa.
        let accented = note("Cafe visit", ["Meet at the caf\u{00E9}"]) // cafe with an accent in body
        XCTAssertTrue(NoteSearch.matches(accented, query: "cafe"))

        let plain = note("resume", ["send the resume"])
        XCTAssertTrue(NoteSearch.matches(plain, query: "r\u{00E9}sum\u{00E9}")) // accented query, plain note
    }

    // MARK: - No match

    func testNoMatch() {
        let n = note("Grocery list", ["milk", "eggs"])
        XCTAssertFalse(NoteSearch.matches(n, query: "xyzzy"))
    }

    // MARK: - Empty / whitespace query

    func testEmptyQueryMatchesEverything() {
        let n = note("anything", ["body"])
        XCTAssertTrue(NoteSearch.matches(n, query: ""))
        XCTAssertTrue(NoteSearch.matches(n, query: "   "))
    }

    func testIsActive() {
        XCTAssertFalse(NoteSearch.isActive(""))
        XCTAssertFalse(NoteSearch.isActive("   \n\t "))
        XCTAssertTrue(NoteSearch.isActive("a"))
        XCTAssertTrue(NoteSearch.isActive("  hello  "))
    }

    // MARK: - results: global across folders, order preserved

    func testResultsAreGlobalAcrossFolders() {
        let notes = [
            note("root", ["find me here"], folder: [], epoch: 3_000),
            note("work", ["nothing"], folder: ["Work"], epoch: 2_000),
            note("deep", ["also find me"], folder: ["Work", "Q1"], epoch: 1_000),
        ]
        let results = NoteSearch.results(in: notes, query: "find me")
        XCTAssertEqual(results.map(\.title), ["root", "deep"])
    }

    func testResultsPreserveInputOrder() {
        // The store hands notes newest first; results must keep that order (no re-ranking, spec 0021).
        let notes = [
            note("newest", ["alpha"], epoch: 3_000),
            note("middle", ["alpha"], epoch: 2_000),
            note("oldest", ["alpha"], epoch: 1_000),
        ]
        let results = NoteSearch.results(in: notes, query: "alpha")
        XCTAssertEqual(results.map(\.title), ["newest", "middle", "oldest"])
    }

    func testEmptyQueryReturnsAllUnchanged() {
        let notes = [note("a", ["x"]), note("b", ["y"])]
        XCTAssertEqual(NoteSearch.results(in: notes, query: "").map(\.title), ["a", "b"])
        XCTAssertEqual(NoteSearch.results(in: notes, query: "   ").map(\.title), ["a", "b"])
    }

    func testResultsNoMatchIsEmpty() {
        let notes = [note("a", ["x"]), note("b", ["y"])]
        XCTAssertTrue(NoteSearch.results(in: notes, query: "zzz").isEmpty)
    }
}
