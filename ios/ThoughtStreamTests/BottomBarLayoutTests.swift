import XCTest
@testable import ThoughtStream

/// `FolderScreenState` (spec 0021): the pure selection of which content state a list/folder screen
/// shows - empty-store CTA, active-search results, no-matches, or the normal folder list - plus whether
/// the search field is visible in each state.
final class BottomBarLayoutTests: XCTestCase {
    // MARK: - State selection

    func testEmptyStoreRegardlessOfSearch() {
        // With no thoughts at all, it is always the empty-store CTA - a search cannot find anything.
        XCTAssertEqual(
            FolderScreenState.select(storeHasThoughts: false, searchActive: false, hasSearchMatches: false),
            .emptyStore
        )
        XCTAssertEqual(
            FolderScreenState.select(storeHasThoughts: false, searchActive: true, hasSearchMatches: false),
            .emptyStore
        )
    }

    func testNormalWhenNotSearching() {
        XCTAssertEqual(
            FolderScreenState.select(storeHasThoughts: true, searchActive: false, hasSearchMatches: false),
            .normal
        )
    }

    func testSearchResultsWhenActiveAndMatched() {
        XCTAssertEqual(
            FolderScreenState.select(storeHasThoughts: true, searchActive: true, hasSearchMatches: true),
            .searchResults
        )
    }

    func testNoMatchesWhenActiveAndNoMatch() {
        XCTAssertEqual(
            FolderScreenState.select(storeHasThoughts: true, searchActive: true, hasSearchMatches: false),
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

    // MARK: - Thought-detail bottom bar decision (spec 0021)

    /// While editing the title or body, the thought-detail bottom bar is HIDDEN entirely - so the search
    /// field never renders under the keyboard and a brand-new thought does not present two competing text
    /// fields (engineer + architect review).
    func testThoughtDetailBarHiddenWhileEditing() {
        let d = ThoughtDetailBottomBar.decide(
            canSearch: true, canResume: true, resumeApplies: true,
            isEditing: true, isUnsavedNewThought: false)
        XCTAssertFalse(d.isVisible)
        XCTAssertFalse(d.showsSearch)
        XCTAssertFalse(d.showsResume)
    }

    /// A normal saved thought (not editing) with both affordances available shows the search field and the
    /// resume icon.
    func testThoughtDetailBarShowsSearchAndResumeWhenNotEditing() {
        let d = ThoughtDetailBottomBar.decide(
            canSearch: true, canResume: true, resumeApplies: true,
            isEditing: false, isUnsavedNewThought: false)
        XCTAssertTrue(d.isVisible)
        XCTAssertTrue(d.showsSearch)
        XCTAssertTrue(d.showsResume)
    }

    /// Resume is suppressed when the retention setting makes it inapplicable, even for a saved thought.
    func testThoughtDetailBarHidesResumeWhenNotApplicable() {
        let d = ThoughtDetailBottomBar.decide(
            canSearch: true, canResume: true, resumeApplies: false,
            isEditing: false, isUnsavedNewThought: false)
        XCTAssertTrue(d.isVisible, "search still shows")
        XCTAssertTrue(d.showsSearch)
        XCTAssertFalse(d.showsResume)
    }

    /// A brand-new, still-empty thought shows the search field but NOT resume (nothing to record onto yet).
    func testThoughtDetailBarHidesResumeForUnsavedNewThought() {
        let d = ThoughtDetailBottomBar.decide(
            canSearch: true, canResume: true, resumeApplies: true,
            isEditing: false, isUnsavedNewThought: true)
        XCTAssertTrue(d.showsSearch)
        XCTAssertFalse(d.showsResume)
    }

    /// With neither affordance available (a bare/preview call site with no search and no resume), the bar
    /// is not shown at all.
    func testThoughtDetailBarHiddenWhenNoAffordances() {
        let d = ThoughtDetailBottomBar.decide(
            canSearch: false, canResume: false, resumeApplies: true,
            isEditing: false, isUnsavedNewThought: false)
        XCTAssertFalse(d.isVisible)
    }

    /// Resume-only (no search) still shows the bar so the resume icon is reachable.
    func testThoughtDetailBarVisibleForResumeOnly() {
        let d = ThoughtDetailBottomBar.decide(
            canSearch: false, canResume: true, resumeApplies: true,
            isEditing: false, isUnsavedNewThought: false)
        XCTAssertTrue(d.isVisible)
        XCTAssertFalse(d.showsSearch)
        XCTAssertTrue(d.showsResume)
    }
}
