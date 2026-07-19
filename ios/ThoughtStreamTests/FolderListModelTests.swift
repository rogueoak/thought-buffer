import XCTest
@testable import ThoughtStream

/// `FolderListModel` (spec 0010): the pure projection that filters notes to a folder path, interleaves
/// child folders with those notes, and orders both by the shared `NoteSortOrder` comparator. A folder's
/// sort date is the newest note anywhere under it (recursively); its title is its name.
@MainActor
final class FolderListModelTests: XCTestCase {
    private func note(_ title: String, _ epoch: TimeInterval, folder: [String] = [], id: UUID = UUID()) -> Note {
        Note(id: id, title: title, paragraphs: ["b"], createdAt: Date(timeIntervalSince1970: epoch), folderPath: folder)
    }

    /// Reduce a projected list to a compact, comparable form: "F:name" for a folder, "N:title" for a
    /// note, in the produced order.
    private func tags(_ items: [FolderListItem]) -> [String] {
        items.map { item in
            switch item {
            case let .folder(name, _): return "F:\(name)"
            case let .note(note): return "N:\(note.title)"
            }
        }
    }

    // MARK: - Filter by path

    func testOnlyNotesAtCurrentPathAreShown() {
        let notes = [
            note("root note", 1_000, folder: []),
            note("work note", 2_000, folder: ["Work"]),
            note("deep note", 3_000, folder: ["Work", "Q1"]),
        ]
        let items = FolderListModel.items(
            allNotes: notes,
            childFolderNames: ["Work"],
            currentPath: [],
            sortOrder: .newest
        )
        // At root: the root note and the child folder "Work" - NOT the notes inside Work.
        XCTAssertEqual(Set(tags(items)), Set(["N:root note", "F:Work"]))
    }

    func testNotesInsideAFolderShowAtThatPath() {
        let notes = [
            note("root note", 1_000, folder: []),
            note("work note", 2_000, folder: ["Work"]),
            note("deep note", 3_000, folder: ["Work", "Q1"]),
        ]
        let items = FolderListModel.items(
            allNotes: notes,
            childFolderNames: ["Q1"],
            currentPath: ["Work"],
            sortOrder: .newest
        )
        XCTAssertEqual(Set(tags(items)), Set(["N:work note", "F:Q1"]))
    }

    // MARK: - Interleave + sort order

    func testNewestInterleavesFolderByItsNewestDescendant() {
        // Folder "Work" newest descendant is 5_000; it should interleave between the 6_000 and 4_000
        // root notes under newest-first.
        let notes = [
            note("newest root", 6_000, folder: []),
            note("older root", 4_000, folder: []),
            note("work note", 5_000, folder: ["Work"]),
        ]
        let items = FolderListModel.items(
            allNotes: notes,
            childFolderNames: ["Work"],
            currentPath: [],
            sortOrder: .newest
        )
        XCTAssertEqual(tags(items), ["N:newest root", "F:Work", "N:older root"])
    }

    func testOldestReversesTheInterleave() {
        let notes = [
            note("newest root", 6_000, folder: []),
            note("older root", 4_000, folder: []),
            note("work note", 5_000, folder: ["Work"]),
        ]
        let items = FolderListModel.items(
            allNotes: notes,
            childFolderNames: ["Work"],
            currentPath: [],
            sortOrder: .oldest
        )
        XCTAssertEqual(tags(items), ["N:older root", "F:Work", "N:newest root"])
    }

    func testTitleAZInterleavesFolderNameAmongNoteTitles() {
        let notes = [
            note("Apple", 1_000, folder: []),
            note("Zebra", 2_000, folder: []),
            note("mango", 3_000, folder: ["Mango"]), // folder title = "Mango"
        ]
        let items = FolderListModel.items(
            allNotes: notes,
            childFolderNames: ["Mango"],
            currentPath: [],
            sortOrder: .titleAZ
        )
        // Case-insensitive: Apple, Mango (folder), Zebra.
        XCTAssertEqual(tags(items), ["N:Apple", "F:Mango", "N:Zebra"])
    }

    func testTitleZAReversesTitleOrder() {
        let notes = [
            note("Apple", 1_000, folder: []),
            note("Zebra", 2_000, folder: []),
            note("mango", 3_000, folder: ["Mango"]),
        ]
        let items = FolderListModel.items(
            allNotes: notes,
            childFolderNames: ["Mango"],
            currentPath: [],
            sortOrder: .titleZA
        )
        XCTAssertEqual(tags(items), ["N:Zebra", "F:Mango", "N:Apple"])
    }

    // MARK: - Folder date = newest descendant (recursive)

    func testFolderDateIsNewestDescendantAcrossSubfolders() {
        // "Work" itself holds an old note (1_000) but a deep subfolder holds a newer one (9_000): the
        // folder should sort as if it were dated 9_000 (newest first puts it at the top).
        let notes = [
            note("top root", 5_000, folder: []),
            note("work old", 1_000, folder: ["Work"]),
            note("work deep new", 9_000, folder: ["Work", "Q1"]),
        ]
        let items = FolderListModel.items(
            allNotes: notes,
            childFolderNames: ["Work"],
            currentPath: [],
            sortOrder: .newest
        )
        XCTAssertEqual(tags(items), ["F:Work", "N:top root"])
    }

    func testEmptyFolderSortsToTheEndUnderNewest() {
        // An empty folder has no descendant notes, so its date is distantPast: newest-first puts it
        // LAST, after every dated note.
        let notes = [note("only note", 5_000, folder: [])]
        let items = FolderListModel.items(
            allNotes: notes,
            childFolderNames: ["Empty"],
            currentPath: [],
            sortOrder: .newest
        )
        XCTAssertEqual(tags(items), ["N:only note", "F:Empty"])
    }

    func testNewestDescendantDateHelperIsDistantPastForEmptyFolder() {
        let notes = [note("elsewhere", 5_000, folder: ["Other"])]
        let date = FolderListModel.newestDescendantDate(under: ["Empty"], in: notes)
        XCTAssertEqual(date, .distantPast)
    }

    func testNewestDescendantDateHelperPicksTheMaxUnderThePrefix() {
        let notes = [
            note("a", 1_000, folder: ["Work"]),
            note("b", 8_000, folder: ["Work", "Deep"]),
            note("c", 9_999, folder: ["Other"]), // not under Work: ignored
        ]
        let date = FolderListModel.newestDescendantDate(under: ["Work"], in: notes)
        XCTAssertEqual(date, Date(timeIntervalSince1970: 8_000))
    }

    // MARK: - Determinism

    func testEmptyEverythingProducesNoRows() {
        let items = FolderListModel.items(allNotes: [], childFolderNames: [], currentPath: [], sortOrder: .newest)
        XCTAssertTrue(items.isEmpty)
    }
}
