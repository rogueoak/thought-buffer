import SwiftUI

/// Pure, unit-testable layout decisions for iPad adaptivity (spec 0022), factored out of the SwiftUI
/// views the same way `FolderScreenState` / `ThoughtDetailBottomBar` (spec 0021) were. No view state, so
/// the "which navigation container" and "one shared search projection" choices are provable without UI.

/// Which navigation container the Thoughts root presents, chosen by the horizontal size class. On a
/// REGULAR width (iPad, and iPhone landscape where it fits) the root is a `NavigationSplitView` - folders
/// in the sidebar, the selected folder's thoughts in the content column, the thought detail in its own
/// column. On COMPACT width it stays the single `NavigationStack` (iPhone portrait), unchanged from before
/// this milestone. The mapping is the whole decision, kept here so it is tested exhaustively rather than
/// branched inline in `body`.
enum StreamContainer: Equatable {
    /// The multi-column split view for a wide canvas (regular width).
    case split
    /// The single navigation stack (compact width) - today's iPhone behavior.
    case stack

    /// Choose the container for a horizontal size class. A nil size class (not yet resolved) defaults to
    /// the compact `.stack`, so the first frame before SwiftUI reports a class is the safe, unchanged
    /// iPhone layout rather than a split view that then collapses.
    static func decide(horizontalSizeClass: UserInterfaceSizeClass?) -> StreamContainer {
        horizontalSizeClass == .regular ? .split : .stack
    }
}

/// The ONE search + content-state projection for a folder screen (spec 0021's `resolveContent`, lifted to
/// a pure seam for spec 0022). Under the `NavigationSplitView` the sidebar and content columns are both
/// folder screens on-screen at once; each must NOT run its own copy of the search scan against the one
/// shared query, or two search surfaces fight one state. So the projection is computed ONCE - at the split
/// container for the split layout, or once per screen for the stack - and this pure function is that single
/// definition: it selects the `FolderScreenState` and the flat global results together, scanning the
/// `thoughts x paragraphs` search at most once, and only when a search is actually active.
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
}
