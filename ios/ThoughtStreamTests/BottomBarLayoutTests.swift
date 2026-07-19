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

    /// Keep-search-focus invariant (feedback 0024): typing the FIRST character flips the resolved state from
    /// `.normal` to `.searchResults` (or `.noMatches` if it matches nothing). Across that flip the search
    /// field must stay MOUNTED - `showsSearchField` stays true - so the `TextField` is never removed and the
    /// keyboard/focus is not dropped after one keystroke. The stable field identity is device-verified; this
    /// pins the pure precondition (the field never unmounts on the transition) so a regression that hides the
    /// field mid-search is caught here.
    func testSearchFieldStaysMountedAcrossFirstKeystrokeTransition() {
        // Before the keystroke: a non-empty store, no active search -> normal folder list, field visible.
        let before = FolderScreenState.select(
            storeHasThoughts: true, searchActive: false, hasSearchMatches: false)
        XCTAssertEqual(before, .normal)
        XCTAssertTrue(before.showsSearchField)

        // First keystroke matches something -> results list, and the field is STILL mounted.
        let afterWithMatches = FolderScreenState.select(
            storeHasThoughts: true, searchActive: true, hasSearchMatches: true)
        XCTAssertEqual(afterWithMatches, .searchResults)
        XCTAssertTrue(afterWithMatches.showsSearchField)

        // First keystroke matches nothing -> no-matches state, and the field is STILL mounted so the user
        // can keep typing / clear without refocusing.
        let afterNoMatches = FolderScreenState.select(
            storeHasThoughts: true, searchActive: true, hasSearchMatches: false)
        XCTAssertEqual(afterNoMatches, .noMatches)
        XCTAssertTrue(afterNoMatches.showsSearchField)
    }

    /// One-persistent-List invariant (feedback 0029, item 8): the normal, results, and no-matches states all
    /// render through the SAME `List` (only the rows change), so the `.safeAreaInset` search field's host is
    /// never torn down while typing - the third and final fix for the dropped-focus bug. Only the empty-store
    /// CTA renders outside that list, and it has no search field, so the sole transition off the shared list
    /// happens when the store goes from zero thoughts to some, never mid-typing. A refactor that reintroduced
    /// a distinct list view for a searching state (reviving the bug) would flip one of these and fail here.
    func testSearchingStatesShareOnePersistentList() {
        // Every state that shows the search field must use the ONE shared List, so the field never re-mounts
        // on a query-driven state flip.
        XCTAssertTrue(FolderScreenState.normal.contentUsesList)
        XCTAssertTrue(FolderScreenState.searchResults.contentUsesList)
        XCTAssertTrue(FolderScreenState.noMatches.contentUsesList)
        // The empty store is the only state OUTSIDE that list - and it hides the field, so no focus is lost.
        XCTAssertFalse(FolderScreenState.emptyStore.contentUsesList)

        // The two invariants agree everywhere: a state uses the shared list exactly when it shows the field.
        for state in [FolderScreenState.emptyStore, .searchResults, .noMatches, .normal] {
            XCTAssertEqual(
                state.contentUsesList, state.showsSearchField,
                "\(state): the field lives in the shared list, so it shows the field iff it uses that list")
        }
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

    // MARK: - List title size (feedback 0020)

    /// The below-the-toolbar list title is ONE Canopy step below the system large title: the H3-equivalent
    /// `sizeX3xl` (30), not the larger `sizeX4xl` (36). Asserting against the token (not a raw point size)
    /// keeps the "one step down, on the Canopy scale" rule verifiable without rendering.
    func testListTitleUsesCanopyH3Size() {
        XCTAssertEqual(StreamListTitle.fontSize, CanopyFont.sizeX3xl)
        // One step below the next size up on the Canopy scale (the old, larger header).
        XCTAssertLessThan(StreamListTitle.fontSize, CanopyFont.sizeX4xl)
    }
}
