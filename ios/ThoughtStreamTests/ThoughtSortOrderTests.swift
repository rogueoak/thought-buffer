import XCTest
@testable import ThoughtStream

/// The pure `ThoughtSortOrder.sort` over `[Thought]` (spec 0010): each order reorders correctly and ties
/// break deterministically so the same input always yields the same output.
final class ThoughtSortOrderTests: XCTestCase {
    private func thought(_ title: String, _ epoch: TimeInterval, id: UUID = UUID()) -> Thought {
        Thought(id: id, title: title, paragraphs: ["b"], createdAt: Date(timeIntervalSince1970: epoch))
    }

    func testNewestFirst() {
        let thoughts = [thought("a", 1_000), thought("b", 3_000), thought("c", 2_000)]
        XCTAssertEqual(ThoughtSortOrder.newest.sort(thoughts).map(\.title), ["b", "c", "a"])
    }

    func testOldestFirst() {
        let thoughts = [thought("a", 1_000), thought("b", 3_000), thought("c", 2_000)]
        XCTAssertEqual(ThoughtSortOrder.oldest.sort(thoughts).map(\.title), ["a", "c", "b"])
    }

    func testTitleAZ() {
        let thoughts = [thought("Banana", 1_000), thought("apple", 2_000), thought("Cherry", 3_000)]
        // Case-insensitive: apple sorts before Banana.
        XCTAssertEqual(ThoughtSortOrder.titleAZ.sort(thoughts).map(\.title), ["apple", "Banana", "Cherry"])
    }

    func testTitleZA() {
        let thoughts = [thought("Banana", 1_000), thought("apple", 2_000), thought("Cherry", 3_000)]
        XCTAssertEqual(ThoughtSortOrder.titleZA.sort(thoughts).map(\.title), ["Cherry", "Banana", "apple"])
    }

    /// Equal timestamps tie-break by title, so a date order is stable rather than run-dependent.
    func testDateOrderTieBreaksByTitle() {
        let thoughts = [thought("zebra", 5_000), thought("alpha", 5_000), thought("mango", 5_000)]
        // All same date: newest falls back to title A-Z.
        XCTAssertEqual(ThoughtSortOrder.newest.sort(thoughts).map(\.title), ["alpha", "mango", "zebra"])
    }

    /// Equal titles tie-break by date (newest first), so a title order is stable.
    func testTitleOrderTieBreaksByDate() {
        let thoughts = [thought("Same", 1_000), thought("Same", 3_000), thought("Same", 2_000)]
        XCTAssertEqual(ThoughtSortOrder.titleAZ.sort(thoughts).map(\.createdAt.timeIntervalSince1970),
                       [3_000, 2_000, 1_000])
    }

    /// Fully-equal primary and secondary keys still tie-break by id, so the order is total and
    /// deterministic (no run-to-run reordering).
    func testFullTieBreaksByIdDeterministically() {
        let idA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let idB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let a = thought("Same", 5_000, id: idA)
        let b = thought("Same", 5_000, id: idB)
        // idA < idB, so a comes first regardless of input order.
        XCTAssertEqual(ThoughtSortOrder.newest.sort([b, a]).map(\.id), [idA, idB])
        XCTAssertEqual(ThoughtSortOrder.titleAZ.sort([b, a]).map(\.id), [idA, idB])
    }

    func testDefaultIsNewest() {
        XCTAssertEqual(ThoughtSortOrder.default, .newest)
    }

    /// The shared `areInIncreasingOrder` comparator orders two `SortKey`s correctly for each order.
    /// This is the seam PR B reuses to sort folders among thoughts by the same key.
    func testSortKeyComparatorOrdersEachOrder() {
        let older = ThoughtSortOrder.SortKey(title: "apple", date: Date(timeIntervalSince1970: 1_000), tieBreak: "1")
        let newer = ThoughtSortOrder.SortKey(title: "banana", date: Date(timeIntervalSince1970: 2_000), tieBreak: "2")

        // Newest first: newer before older.
        XCTAssertTrue(ThoughtSortOrder.newest.areInIncreasingOrder(newer, older))
        XCTAssertFalse(ThoughtSortOrder.newest.areInIncreasingOrder(older, newer))

        // Oldest first: older before newer.
        XCTAssertTrue(ThoughtSortOrder.oldest.areInIncreasingOrder(older, newer))
        XCTAssertFalse(ThoughtSortOrder.oldest.areInIncreasingOrder(newer, older))

        // Title A-Z: "apple" before "banana".
        XCTAssertTrue(ThoughtSortOrder.titleAZ.areInIncreasingOrder(older, newer))
        XCTAssertFalse(ThoughtSortOrder.titleAZ.areInIncreasingOrder(newer, older))

        // Title Z-A: "banana" before "apple".
        XCTAssertTrue(ThoughtSortOrder.titleZA.areInIncreasingOrder(newer, older))
        XCTAssertFalse(ThoughtSortOrder.titleZA.areInIncreasingOrder(older, newer))
    }
}
