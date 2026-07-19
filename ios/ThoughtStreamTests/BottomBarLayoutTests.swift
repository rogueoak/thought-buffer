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

    // MARK: - Note-detail bottom bar decision (spec 0021)

    /// While editing the title or body, the note-detail bottom bar is HIDDEN entirely - so the search
    /// field never renders under the keyboard and a brand-new note does not present two competing text
    /// fields (engineer + architect review).
    func testNoteDetailBarHiddenWhileEditing() {
        let d = NoteDetailBottomBar.decide(
            canSearch: true, canResume: true, resumeApplies: true,
            isEditing: true, isUnsavedNewNote: false)
        XCTAssertFalse(d.isVisible)
        XCTAssertFalse(d.showsSearch)
        XCTAssertFalse(d.showsResume)
    }

    /// A normal saved note (not editing) with both affordances available shows the search field and the
    /// resume icon.
    func testNoteDetailBarShowsSearchAndResumeWhenNotEditing() {
        let d = NoteDetailBottomBar.decide(
            canSearch: true, canResume: true, resumeApplies: true,
            isEditing: false, isUnsavedNewNote: false)
        XCTAssertTrue(d.isVisible)
        XCTAssertTrue(d.showsSearch)
        XCTAssertTrue(d.showsResume)
    }

    /// Resume is suppressed when the retention setting makes it inapplicable, even for a saved note.
    func testNoteDetailBarHidesResumeWhenNotApplicable() {
        let d = NoteDetailBottomBar.decide(
            canSearch: true, canResume: true, resumeApplies: false,
            isEditing: false, isUnsavedNewNote: false)
        XCTAssertTrue(d.isVisible, "search still shows")
        XCTAssertTrue(d.showsSearch)
        XCTAssertFalse(d.showsResume)
    }

    /// A brand-new, still-empty note shows the search field but NOT resume (nothing to record onto yet).
    func testNoteDetailBarHidesResumeForUnsavedNewNote() {
        let d = NoteDetailBottomBar.decide(
            canSearch: true, canResume: true, resumeApplies: true,
            isEditing: false, isUnsavedNewNote: true)
        XCTAssertTrue(d.showsSearch)
        XCTAssertFalse(d.showsResume)
    }

    /// With neither affordance available (a bare/preview call site with no search and no resume), the bar
    /// is not shown at all.
    func testNoteDetailBarHiddenWhenNoAffordances() {
        let d = NoteDetailBottomBar.decide(
            canSearch: false, canResume: false, resumeApplies: true,
            isEditing: false, isUnsavedNewNote: false)
        XCTAssertFalse(d.isVisible)
    }

    /// Resume-only (no search) still shows the bar so the resume icon is reachable.
    func testNoteDetailBarVisibleForResumeOnly() {
        let d = NoteDetailBottomBar.decide(
            canSearch: false, canResume: true, resumeApplies: true,
            isEditing: false, isUnsavedNewNote: false)
        XCTAssertTrue(d.isVisible)
        XCTAssertFalse(d.showsSearch)
        XCTAssertTrue(d.showsResume)
    }
}
