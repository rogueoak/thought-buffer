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

    // MARK: - Bar-ownership mapping (single-bottom-bar invariant)

    /// The single-bottom-bar invariant, as a tested decision (spec 0022): the COMPACT stack's folder screen
    /// owns its own bottom bar (one screen at a time), and the SPLIT columns do NOT (the container lifts one
    /// shared bar above them). Locking this in a test means a future edit cannot silently give a split column
    /// its own bar (two fields fighting one state) or drop the iPhone bar.
    func testCompactFolderScreenOwnsItsBottomBar() {
        XCTAssertTrue(StreamContainer.stack.folderScreenShowsOwnBottomBar)
    }

    func testSplitColumnsDoNotOwnABottomBar() {
        XCTAssertFalse(StreamContainer.split.folderScreenShowsOwnBottomBar)
    }

    /// The compact stack's pushed detail RE-HOSTS the shared bottom player (feedback 0027): a `NavigationStack`
    /// push swaps the pushing screen's `safeAreaInset`, so the detail must host the player itself or the
    /// transport vanishes on the thought page.
    func testCompactDetailHostsTheBottomPlayer() {
        XCTAssertTrue(StreamContainer.stack.detailHostsBottomPlayer)
    }

    /// The split view's detail column does NOT host the bottom player (feedback 0027): the player is lifted
    /// above all columns once, so hosting it in the detail column too would double-render it. Locking this in a
    /// test means a future lifting container cannot silently ship two players.
    func testSplitDetailDoesNotHostTheBottomPlayer() {
        XCTAssertFalse(StreamContainer.split.detailHostsBottomPlayer)
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

    // MARK: - Sidebar projection (exactly one results list across the split)

    /// The SIDEBAR keeps its NORMAL folder tree during an active search that MATCHED (spec 0022 fix): the
    /// one global results list shows in the content column only, so it is not double-rendered beside the
    /// sidebar. The demotion drops the results too.
    func testSidebarDemotesSearchResultsToNormal() {
        let full = StreamSearchProjection.Result(state: .searchResults, results: [thought(title: "Match")])
        let sidebar = StreamSearchProjection.sidebarProjection(from: full)
        XCTAssertEqual(sidebar.state, .normal)
        XCTAssertTrue(sidebar.results.isEmpty)
    }

    /// The sidebar also demotes the no-matches state to normal, so an active search that found nothing does
    /// not blank the sidebar - it keeps showing the folder tree while the content column reports no matches.
    func testSidebarDemotesNoMatchesToNormal() {
        let full = StreamSearchProjection.Result(state: .noMatches, results: [])
        XCTAssertEqual(StreamSearchProjection.sidebarProjection(from: full).state, .normal)
    }

    /// The empty-store and normal states pass through unchanged - the sidebar shows the CTA / folder tree
    /// exactly as the content column would.
    func testSidebarLeavesEmptyStoreAndNormalUntouched() {
        let empty = StreamSearchProjection.Result(state: .emptyStore, results: [])
        XCTAssertEqual(StreamSearchProjection.sidebarProjection(from: empty), empty)
        let normal = StreamSearchProjection.Result(state: .normal, results: [])
        XCTAssertEqual(StreamSearchProjection.sidebarProjection(from: normal), normal)
    }

    // MARK: - Split detail reconcile (no stale detail column)

    /// Deleting the thought open in the detail column clears the selection (spec 0022), so the user cannot
    /// read / edit / resume a trashed thought.
    func testDeleteOfShownThoughtClearsSelection() {
        let shown = UUID()
        XCTAssertTrue(SplitDetailReconcile.deleteClearsSelection(deletedId: shown, shownThoughtId: shown))
    }

    /// Deleting some OTHER thought (a swipe in the list) leaves the open thought alone.
    func testDeleteOfOtherThoughtKeepsSelection() {
        XCTAssertFalse(SplitDetailReconcile.deleteClearsSelection(deletedId: UUID(), shownThoughtId: UUID()))
    }

    /// With nothing shown (placeholder or an unsaved new-thought draft, which has no persisted id), a delete
    /// clears nothing.
    func testDeleteClearsNothingWhenNoThoughtShown() {
        XCTAssertFalse(SplitDetailReconcile.deleteClearsSelection(deletedId: UUID(), shownThoughtId: nil))
    }

    // MARK: - Split content-column subject reconcile (spec 0026)

    func testContentSubjectSurvivesWhenUserFolderStillExists() {
        XCTAssertTrue(SplitDetailReconcile.contentSubjectSurvives(.userFolder("Work"), inFolderNames: ["Work", "Home"]))
    }

    func testContentSubjectDoesNotSurviveWhenUserFolderRenamedOrDeleted() {
        // The shown folder is gone from the reloaded names (renamed to "Job" or deleted): the content column
        // must revert, so this returns false.
        XCTAssertFalse(SplitDetailReconcile.contentSubjectSurvives(.userFolder("Work"), inFolderNames: ["Job", "Home"]))
        XCTAssertFalse(SplitDetailReconcile.contentSubjectSurvives(.userFolder("Work"), inFolderNames: []))
    }

    func testAliasSubjectAlwaysSurvives() {
        // Aliases are virtual - never renamed/deleted - so they survive any folder-names reload.
        XCTAssertTrue(SplitDetailReconcile.contentSubjectSurvives(.alias(.allThoughts), inFolderNames: []))
        XCTAssertTrue(SplitDetailReconcile.contentSubjectSurvives(.alias(.recents), inFolderNames: ["Work"]))
    }

    func testNoSubjectTriviallySurvives() {
        XCTAssertTrue(SplitDetailReconcile.contentSubjectSurvives(nil, inFolderNames: ["Work"]))
    }

    // MARK: - Helpers

    private func thought(title: String, folderPath: [String] = []) -> Thought {
        Thought(title: title, paragraphs: [title], createdAt: Date(), folderPath: folderPath)
    }
}
