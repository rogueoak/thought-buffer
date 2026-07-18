import XCTest
@testable import ThoughtStream

/// The pure `NoteSortOrder.sort` over `[Note]` (spec 0010): each order reorders correctly and ties
/// break deterministically so the same input always yields the same output.
final class NoteSortOrderTests: XCTestCase {
    private func note(_ title: String, _ epoch: TimeInterval, id: UUID = UUID()) -> Note {
        Note(id: id, title: title, paragraphs: ["b"], createdAt: Date(timeIntervalSince1970: epoch))
    }

    func testNewestFirst() {
        let notes = [note("a", 1_000), note("b", 3_000), note("c", 2_000)]
        XCTAssertEqual(NoteSortOrder.newest.sort(notes).map(\.title), ["b", "c", "a"])
    }

    func testOldestFirst() {
        let notes = [note("a", 1_000), note("b", 3_000), note("c", 2_000)]
        XCTAssertEqual(NoteSortOrder.oldest.sort(notes).map(\.title), ["a", "c", "b"])
    }

    func testTitleAZ() {
        let notes = [note("Banana", 1_000), note("apple", 2_000), note("Cherry", 3_000)]
        // Case-insensitive: apple sorts before Banana.
        XCTAssertEqual(NoteSortOrder.titleAZ.sort(notes).map(\.title), ["apple", "Banana", "Cherry"])
    }

    func testTitleZA() {
        let notes = [note("Banana", 1_000), note("apple", 2_000), note("Cherry", 3_000)]
        XCTAssertEqual(NoteSortOrder.titleZA.sort(notes).map(\.title), ["Cherry", "Banana", "apple"])
    }

    /// Equal timestamps tie-break by title, so a date order is stable rather than run-dependent.
    func testDateOrderTieBreaksByTitle() {
        let notes = [note("zebra", 5_000), note("alpha", 5_000), note("mango", 5_000)]
        // All same date: newest falls back to title A-Z.
        XCTAssertEqual(NoteSortOrder.newest.sort(notes).map(\.title), ["alpha", "mango", "zebra"])
    }

    /// Equal titles tie-break by date (newest first), so a title order is stable.
    func testTitleOrderTieBreaksByDate() {
        let notes = [note("Same", 1_000), note("Same", 3_000), note("Same", 2_000)]
        XCTAssertEqual(NoteSortOrder.titleAZ.sort(notes).map(\.createdAt.timeIntervalSince1970),
                       [3_000, 2_000, 1_000])
    }

    /// Fully-equal primary and secondary keys still tie-break by id, so the order is total and
    /// deterministic (no run-to-run reordering).
    func testFullTieBreaksByIdDeterministically() {
        let idA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let idB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let a = note("Same", 5_000, id: idA)
        let b = note("Same", 5_000, id: idB)
        // idA < idB, so a comes first regardless of input order.
        XCTAssertEqual(NoteSortOrder.newest.sort([b, a]).map(\.id), [idA, idB])
        XCTAssertEqual(NoteSortOrder.titleAZ.sort([b, a]).map(\.id), [idA, idB])
    }

    func testDefaultIsNewest() {
        XCTAssertEqual(NoteSortOrder.default, .newest)
    }

    /// The shared `areInIncreasingOrder` comparator orders two `SortKey`s correctly for each order.
    /// This is the seam PR B reuses to sort folders among notes by the same key.
    func testSortKeyComparatorOrdersEachOrder() {
        let older = NoteSortOrder.SortKey(title: "apple", date: Date(timeIntervalSince1970: 1_000), tieBreak: "1")
        let newer = NoteSortOrder.SortKey(title: "banana", date: Date(timeIntervalSince1970: 2_000), tieBreak: "2")

        // Newest first: newer before older.
        XCTAssertTrue(NoteSortOrder.newest.areInIncreasingOrder(newer, older))
        XCTAssertFalse(NoteSortOrder.newest.areInIncreasingOrder(older, newer))

        // Oldest first: older before newer.
        XCTAssertTrue(NoteSortOrder.oldest.areInIncreasingOrder(older, newer))
        XCTAssertFalse(NoteSortOrder.oldest.areInIncreasingOrder(newer, older))

        // Title A-Z: "apple" before "banana".
        XCTAssertTrue(NoteSortOrder.titleAZ.areInIncreasingOrder(older, newer))
        XCTAssertFalse(NoteSortOrder.titleAZ.areInIncreasingOrder(newer, older))

        // Title Z-A: "banana" before "apple".
        XCTAssertTrue(NoteSortOrder.titleZA.areInIncreasingOrder(newer, older))
        XCTAssertFalse(NoteSortOrder.titleZA.areInIncreasingOrder(older, newer))
    }
}
