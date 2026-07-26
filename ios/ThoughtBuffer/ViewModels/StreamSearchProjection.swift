import Foundation

/// The ONE search + content-state projection for a folder screen (spec 0021's `resolveContent`, lifted to
/// a pure seam for spec 0022). Under the `NavigationSplitView` the sidebar and content columns are both
/// folder screens on-screen at once; each must NOT run its own copy of the search scan against the one
/// shared query, or two search surfaces fight one state. So the projection is computed ONCE - at the split
/// container for the split layout, or once per screen for the stack - and this pure function is that single
/// definition: it selects the `FolderScreenState` and the flat global results together, scanning the
/// `thoughts x paragraphs` search at most once, and only when a search is actually active.
///
/// No SwiftUI import (architect review, spec 0022): this and the `FolderScreenState`-style pure logic must
/// stay UI-free so a future Watch target (spec 0023) can reuse the exact same search + state selection. The
/// iPad-bound `StreamContainer` decision (which imports SwiftUI's size class) lives in its own file.
enum StreamSearchProjection {
    /// The resolved screen state and its search results.
    struct Result: Equatable {
        let state: FolderScreenState
        /// The flat global search results (empty unless the state is `.searchResults`).
        let results: [Thought]
    }

    /// Resolve the state + results for the whole search surface.
    ///
    /// - `didLoad`: the feed has completed its initial load AND the current folder's children are known.
    ///   Until then the projection is `.normal` with no results, so a not-yet-loaded feed does not flash the
    ///   empty-store CTA.
    /// - `thoughts`: every loaded thought (search is GLOBAL, across all folders).
    /// - `searchQuery`: the shared live query.
    static func resolve(didLoad: Bool, thoughts: [Thought], searchQuery: String) -> Result {
        guard didLoad else { return Result(state: .normal, results: []) }
        let active = ThoughtSearch.isActive(searchQuery)
        // Only scan when a search is active; the normal/empty states never look at results.
        let results = active ? ThoughtSearch.results(in: thoughts, query: searchQuery) : []
        let state = FolderScreenState.select(
            storeHasThoughts: !thoughts.isEmpty,
            searchActive: active,
            hasSearchMatches: !results.isEmpty
        )
        return Result(state: state, results: results)
    }

    /// The projection for a screen that must NOT show the global results list (spec 0022): the split view's
    /// SIDEBAR. During an active search exactly ONE results list shows across the split (in the content
    /// column), so the sidebar keeps its NORMAL folder tree instead of double-rendering the same global
    /// matches beside it. This demotes an active-search state (`.searchResults` / `.noMatches`) back to
    /// `.normal` and drops the results, while leaving `.emptyStore` and `.normal` untouched. It reuses the
    /// SAME single scan (pass in the already-resolved full projection), so no second scan runs.
    static func sidebarProjection(from full: Result) -> Result {
        switch full.state {
        case .searchResults, .noMatches:
            return Result(state: .normal, results: [])
        case .emptyStore, .normal:
            return full
        }
    }
}
