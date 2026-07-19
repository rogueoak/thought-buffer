import SwiftUI
import XCTest
@testable import ThoughtStream

/// The pure iPad-adaptivity decisions (spec 0022): the size-class -> container choice (`StreamContainer`)
/// and the ONE lifted search/results projection (`StreamSearchProjection`) shared across the split view's
/// columns.
final class AdaptiveLayoutTests: XCTestCase {
    // MARK: - Container choice (size class -> container)

    func testRegularWidthChoosesSplit() {
        XCTAssertEqual(StreamContainer.decide(horizontalSizeClass: .regular), .split)
    }

    func testCompactWidthChoosesStack() {
        XCTAssertEqual(StreamContainer.decide(horizontalSizeClass: .compact), .stack)
    }

    /// A not-yet-resolved size class defaults to the compact stack, so the first frame is the safe,
    /// unchanged iPhone layout rather than a split view that then collapses.
    func testNilSizeClassDefaultsToStack() {
        XCTAssertEqual(StreamContainer.decide(horizontalSizeClass: nil), .stack)
    }

    // MARK: - Lifted search projection (the one shared search surface)

    /// Before the initial load completes, the projection is `.normal` with no results, so a not-yet-loaded
    /// feed does not flash the empty-store CTA (even when the store is genuinely empty at that instant).
    func testNotLoadedIsNormalWithNoResults() {
        let result = StreamSearchProjection.resolve(didLoad: false, thoughts: [], searchQuery: "")
        XCTAssertEqual(result.state, .normal)
        XCTAssertTrue(result.results.isEmpty)
    }

    /// Loaded with an empty store and no query is the empty-store CTA.
    func testLoadedEmptyStoreIsEmptyStore() {
        let result = StreamSearchProjection.resolve(didLoad: true, thoughts: [], searchQuery: "")
        XCTAssertEqual(result.state, .emptyStore)
        XCTAssertTrue(result.results.isEmpty)
    }

    /// Loaded with thoughts and no active query is the normal folder list, and NO scan runs (results empty).
    func testLoadedWithThoughtsNoQueryIsNormal() {
        let thoughts = [thought(title: "Groceries"), thought(title: "Ideas")]
        let result = StreamSearchProjection.resolve(didLoad: true, thoughts: thoughts, searchQuery: "  ")
        XCTAssertEqual(result.state, .normal)
        XCTAssertTrue(result.results.isEmpty, "a whitespace-only query is not active - no scan, no results")
    }

    /// An active query that matches returns the search-results state and the GLOBAL flat matches (across
    /// folders), which is exactly what the ONE lifted search surface renders for the whole split view.
    func testActiveQueryWithMatchesIsSearchResults() {
        let a = thought(title: "Grocery list", folderPath: [])
        let b = thought(title: "Trip plan", folderPath: ["Travel"])
        let c = thought(title: "Grocery budget", folderPath: ["Money"])
        let result = StreamSearchProjection.resolve(
            didLoad: true,
            thoughts: [a, b, c],
            searchQuery: "grocery"
        )
        XCTAssertEqual(result.state, .searchResults)
        XCTAssertEqual(result.results.map(\.id), [a.id, c.id], "global, order-preserving, across folders")
    }

    /// An active query in a non-empty store that matches nothing is the no-matches state with no results.
    func testActiveQueryNoMatchesIsNoMatches() {
        let result = StreamSearchProjection.resolve(
            didLoad: true,
            thoughts: [thought(title: "Groceries")],
            searchQuery: "zzzz-nope"
        )
        XCTAssertEqual(result.state, .noMatches)
        XCTAssertTrue(result.results.isEmpty)
    }

    /// The projection matches the per-screen `FolderScreenState.select` semantics it replaces, so lifting
    /// it above the container did not change the state for any input combination.
    func testProjectionStateMatchesFolderScreenStateSelection() {
        let thoughts = [thought(title: "Alpha")]
        let loadedActiveMatch = StreamSearchProjection.resolve(
            didLoad: true, thoughts: thoughts, searchQuery: "alpha")
        XCTAssertEqual(
            loadedActiveMatch.state,
            FolderScreenState.select(storeHasThoughts: true, searchActive: true, hasSearchMatches: true)
        )
    }

    // MARK: - Helpers

    private func thought(title: String, folderPath: [String] = []) -> Thought {
        Thought(title: title, paragraphs: [title], createdAt: Date(), folderPath: folderPath)
    }
}
