import XCTest
@testable import ThoughtStream

/// `FolderScreenState` (spec 0021): the pure selection of which content state a list/folder screen
/// shows - empty-store CTA, active-search results, no-matches, or the normal folder list - plus whether
/// the search field is visible in each state.
final class BottomBarLayoutTests: XCTestCase {
    // MARK: - State selection

    func testEmptyStoreRegardlessOfSearch() {
        // With no notes at all, it is always the empty-store CTA - a search cannot find anything.
        XCTAssertEqual(
            FolderScreenState.select(storeHasNotes: false, searchActive: false, hasSearchMatches: false),
            .emptyStore
        )
        XCTAssertEqual(
            FolderScreenState.select(storeHasNotes: false, searchActive: true, hasSearchMatches: false),
            .emptyStore
        )
    }

    func testNormalWhenNotSearching() {
        XCTAssertEqual(
            FolderScreenState.select(storeHasNotes: true, searchActive: false, hasSearchMatches: false),
            .normal
        )
    }

    func testSearchResultsWhenActiveAndMatched() {
        XCTAssertEqual(
            FolderScreenState.select(storeHasNotes: true, searchActive: true, hasSearchMatches: true),
            .searchResults
        )
    }

    func testNoMatchesWhenActiveAndNoMatch() {
        XCTAssertEqual(
            FolderScreenState.select(storeHasNotes: true, searchActive: true, hasSearchMatches: false),
            .noMatches
        )
    }

    // MARK: - Search field visibility

    func testSearchFieldHiddenOnlyInEmptyStore() {
        XCTAssertFalse(FolderScreenState.emptyStore.showsSearchField)
        XCTAssertTrue(FolderScreenState.normal.showsSearchField)
        XCTAssertTrue(FolderScreenState.searchResults.showsSearchField)
        // Kept visible in no-matches so the user can refine/clear the query (spec 0021).
        XCTAssertTrue(FolderScreenState.noMatches.showsSearchField)
    }
}
