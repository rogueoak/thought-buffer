import XCTest
@testable import ThoughtStream

/// `FolderListModel` (spec 0010): the pure projection that filters thoughts to a folder path, interleaves
/// child folders with those thoughts, and orders both by the shared `ThoughtSortOrder` comparator. A folder's
/// sort date is the newest thought anywhere under it (recursively); its title is its name.
@MainActor
final class FolderListModelTests: XCTestCase {
    private func thought(_ title: String, _ epoch: TimeInterval, folder: [String] = [], id: UUID = UUID()) -> Thought {
        Thought(id: id, title: title, paragraphs: ["b"], createdAt: Date(timeIntervalSince1970: epoch), folderPath: folder)
    }

    /// Reduce a projected list to a compact, comparable form: "F:name" for a folder, "N:title" for a
    /// thought, in the produced order.
    private func tags(_ items: [FolderListItem]) -> [String] {
        items.map { item in
            switch item {
            case let .folder(name, _): return "F:\(name)"
            case let .thought(thought): return "N:\(thought.title)"
            }
        }
    }

    // MARK: - Filter by path

    func testOnlyThoughtsAtCurrentPathAreShown() {
        let thoughts = [
            thought("root thought", 1_000, folder: []),
            thought("work thought", 2_000, folder: ["Work"]),
            thought("deep thought", 3_000, folder: ["Work", "Q1"]),
        ]
        let items = FolderListModel.items(
            allThoughts: thoughts,
            childFolderNames: ["Work"],
            currentPath: [],
            sortOrder: .newest
        )
        // At root: the root thought and the child folder "Work" - NOT the thoughts inside Work.
        XCTAssertEqual(Set(tags(items)), Set(["N:root thought", "F:Work"]))
    }

    func testThoughtsInsideAFolderShowAtThatPath() {
        let thoughts = [
            thought("root thought", 1_000, folder: []),
            thought("work thought", 2_000, folder: ["Work"]),
            thought("deep thought", 3_000, folder: ["Work", "Q1"]),
        ]
        let items = FolderListModel.items(
            allThoughts: thoughts,
            childFolderNames: ["Q1"],
            currentPath: ["Work"],
            sortOrder: .newest
        )
        XCTAssertEqual(Set(tags(items)), Set(["N:work thought", "F:Q1"]))
    }

    // MARK: - Interleave + sort order

    func testNewestInterleavesFolderByItsNewestDescendant() {
        // Folder "Work" newest descendant is 5_000; it should interleave between the 6_000 and 4_000
        // root thoughts under newest-first.
        let thoughts = [
            thought("newest root", 6_000, folder: []),
            thought("older root", 4_000, folder: []),
            thought("work thought", 5_000, folder: ["Work"]),
        ]
        let items = FolderListModel.items(
            allThoughts: thoughts,
            childFolderNames: ["Work"],
            currentPath: [],
            sortOrder: .newest
        )
        XCTAssertEqual(tags(items), ["N:newest root", "F:Work", "N:older root"])
    }

    func testOldestReversesTheInterleave() {
        let thoughts = [
            thought("newest root", 6_000, folder: []),
            thought("older root", 4_000, folder: []),
            thought("work thought", 5_000, folder: ["Work"]),
        ]
        let items = FolderListModel.items(
            allThoughts: thoughts,
            childFolderNames: ["Work"],
            currentPath: [],
            sortOrder: .oldest
        )
        XCTAssertEqual(tags(items), ["N:older root", "F:Work", "N:newest root"])
    }

    func testTitleAZInterleavesFolderNameAmongThoughtTitles() {
        let thoughts = [
            thought("Apple", 1_000, folder: []),
            thought("Zebra", 2_000, folder: []),
            thought("mango", 3_000, folder: ["Mango"]), // folder title = "Mango"
        ]
        let items = FolderListModel.items(
            allThoughts: thoughts,
            childFolderNames: ["Mango"],
            currentPath: [],
            sortOrder: .titleAZ
        )
        // Case-insensitive: Apple, Mango (folder), Zebra.
        XCTAssertEqual(tags(items), ["N:Apple", "F:Mango", "N:Zebra"])
    }

    func testTitleZAReversesTitleOrder() {
        let thoughts = [
            thought("Apple", 1_000, folder: []),
            thought("Zebra", 2_000, folder: []),
            thought("mango", 3_000, folder: ["Mango"]),
        ]
        let items = FolderListModel.items(
            allThoughts: thoughts,
            childFolderNames: ["Mango"],
            currentPath: [],
            sortOrder: .titleZA
        )
        XCTAssertEqual(tags(items), ["N:Zebra", "F:Mango", "N:Apple"])
    }

    // MARK: - Folder date = newest descendant (recursive)

    func testFolderDateIsNewestDescendantAcrossSubfolders() {
        // "Work" itself holds an old thought (1_000) but a deep subfolder holds a newer one (9_000): the
        // folder should sort as if it were dated 9_000 (newest first puts it at the top).
        let thoughts = [
            thought("top root", 5_000, folder: []),
            thought("work old", 1_000, folder: ["Work"]),
            thought("work deep new", 9_000, folder: ["Work", "Q1"]),
        ]
        let items = FolderListModel.items(
            allThoughts: thoughts,
            childFolderNames: ["Work"],
            currentPath: [],
            sortOrder: .newest
        )
        XCTAssertEqual(tags(items), ["F:Work", "N:top root"])
    }

    func testEmptyFolderSortsToTheEndUnderNewest() {
        // An empty folder has no descendant thoughts, so it sinks to the bottom: newest-first puts it
        // LAST, after every dated thought.
        let thoughts = [thought("only thought", 5_000, folder: [])]
        let items = FolderListModel.items(
            allThoughts: thoughts,
            childFolderNames: ["Empty"],
            currentPath: [],
            sortOrder: .newest
        )
        XCTAssertEqual(tags(items), ["N:only thought", "F:Empty"])
    }

    func testEmptyFolderSortsToTheEndUnderOldestToo() {
        // The fix: an empty folder is held out of the interleave and appended last, so it is LAST
        // under `.oldest` as well - not first (which the old `.distantPast` sentinel produced).
        let thoughts = [thought("only thought", 5_000, folder: [])]
        let items = FolderListModel.items(
            allThoughts: thoughts,
            childFolderNames: ["Empty"],
            currentPath: [],
            sortOrder: .oldest
        )
        XCTAssertEqual(tags(items), ["N:only thought", "F:Empty"])
    }

    func testMultipleEmptyFoldersAreLastAndNameOrderedUnderBothDateOrders() {
        // Two empty folders and a thought: both empties sink below the thought, ordered A-Z (case-insensitive),
        // identically under newest and oldest.
        let thoughts = [thought("only thought", 5_000, folder: [])]
        for order in [ThoughtSortOrder.newest, .oldest] {
            let items = FolderListModel.items(
                allThoughts: thoughts,
                childFolderNames: ["zeta", "Alpha"],
                currentPath: [],
                sortOrder: order
            )
            XCTAssertEqual(tags(items), ["N:only thought", "F:Alpha", "F:zeta"], "order: \(order)")
        }
    }

    func testEmptyFolderWithOnlyEmptySubfolderIsTreatedAsEmpty() {
        // "Parent" holds no thought directly and only an (empty) subfolder: it has zero descendant thoughts,
        // so it is treated as empty and sinks last.
        let thoughts = [thought("root thought", 5_000, folder: [])]
        let items = FolderListModel.items(
            allThoughts: thoughts,
            childFolderNames: ["Parent"],
            currentPath: [],
            sortOrder: .newest
        )
        XCTAssertEqual(tags(items), ["N:root thought", "F:Parent"])
    }

    func testNewestDescendantDateHelperIsDistantPastForEmptyFolder() {
        let thoughts = [thought("elsewhere", 5_000, folder: ["Other"])]
        let date = FolderListModel.newestDescendantDate(under: ["Empty"], in: thoughts)
        XCTAssertEqual(date, .distantPast)
    }

    func testNewestDescendantDateHelperPicksTheMaxUnderThePrefix() {
        let thoughts = [
            thought("a", 1_000, folder: ["Work"]),
            thought("b", 8_000, folder: ["Work", "Deep"]),
            thought("c", 9_999, folder: ["Other"]), // not under Work: ignored
        ]
        let date = FolderListModel.newestDescendantDate(under: ["Work"], in: thoughts)
        XCTAssertEqual(date, Date(timeIntervalSince1970: 8_000))
    }

    // MARK: - Descendant thought count

    func testDescendantThoughtCountCountsDirectThoughts() {
        let thoughts = [
            thought("a", 1_000, folder: ["Work"]),
            thought("b", 2_000, folder: ["Work"]),
            thought("elsewhere", 3_000, folder: ["Other"]),
        ]
        XCTAssertEqual(FolderListModel.descendantThoughtCount(of: ["Work"], in: thoughts), 2)
    }

    func testDescendantThoughtCountCountsNestedDescendants() {
        // A thought directly in Work, plus two deeper in subfolders, all count for Work.
        let thoughts = [
            thought("direct", 1_000, folder: ["Work"]),
            thought("deep 1", 2_000, folder: ["Work", "Q1"]),
            thought("deep 2", 3_000, folder: ["Work", "Q1", "Jan"]),
            thought("outside", 4_000, folder: ["Other"]),
        ]
        XCTAssertEqual(FolderListModel.descendantThoughtCount(of: ["Work"], in: thoughts), 3)
        XCTAssertEqual(FolderListModel.descendantThoughtCount(of: ["Work", "Q1"], in: thoughts), 2)
    }

    func testDescendantThoughtCountIsZeroForFolderWithOnlyEmptySubfolder() {
        // "Parent" holds no thought directly; its only subfolder holds no thought either. The count is 0 -
        // the honest metric, unlike a path-inference that would over-report.
        let thoughts = [thought("elsewhere", 5_000, folder: ["Other"])]
        XCTAssertEqual(FolderListModel.descendantThoughtCount(of: ["Parent"], in: thoughts), 0)
    }

    func testThoughtCountLabelPluralizationBoundaries() {
        XCTAssertEqual(FolderListModel.thoughtCountLabel(0), "No thoughts")
        XCTAssertEqual(FolderListModel.thoughtCountLabel(1), "1 thought")
        XCTAssertEqual(FolderListModel.thoughtCountLabel(2), "2 thoughts")
        XCTAssertEqual(FolderListModel.thoughtCountLabel(42), "42 thoughts")
    }

    // MARK: - Determinism

    func testFolderAndThoughtTieBreakDeterministicallyOnEqualDate() {
        // A folder and a thought share the SAME sort date (2_000). Under newest, the date is equal, so the
        // shared comparator falls to the title tie-break: folder title "Beta" vs thought title "Alpha" -
        // "Alpha" sorts first case-insensitively. This exercises the folder-vs-thought tie path.
        let thoughts = [
            thought("Alpha", 2_000, folder: []),
            thought("beta thought", 2_000, folder: ["Beta"]), // gives folder "Beta" a date of 2_000
        ]
        let items = FolderListModel.items(
            allThoughts: thoughts,
            childFolderNames: ["Beta"],
            currentPath: [],
            sortOrder: .newest
        )
        XCTAssertEqual(tags(items), ["N:Alpha", "F:Beta"])
    }

    func testEmptyEverythingProducesNoRows() {
        let items = FolderListModel.items(allThoughts: [], childFolderNames: [], currentPath: [], sortOrder: .newest)
        XCTAssertTrue(items.isEmpty)
    }
}
