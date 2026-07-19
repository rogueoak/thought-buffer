import Foundation

/// Pure layout-decision logic for the search + bottom-bar redesign (spec 0021), factored out of the
/// SwiftUI views so the state selection and the "which right-side actions" choice are unit-testable
/// rather than trapped in view `body`.

/// Which content state a list/folder screen shows, given whether the whole store is empty, whether a
/// search is active, and whether that search found anything. The view renders one of these; the mapping
/// from raw conditions to the case lives here so it can be tested exhaustively.
enum FolderScreenState: Equatable {
    /// The store has no notes at all: show the centered record + new-note CTA (spec 0021 empty state).
    /// The search field hides in this state (nothing to search).
    case emptyStore
    /// A search is active and matched at least one note: show the flat global results list.
    case searchResults
    /// A search is active but matched nothing in a non-empty store: show a "no matches" message, keeping
    /// the search field visible so the user can edit the query.
    case noMatches
    /// No active search: show the normal interleaved folder list (folders + notes at this path).
    case normal

    /// Select the state.
    ///
    /// - `storeHasNotes`: the whole store has at least one note (across all folders). When false, the
    ///   screen is `.emptyStore` regardless of search - there is nothing to find.
    /// - `searchActive`: the search field has a non-whitespace query (see `NoteSearch.isActive`).
    /// - `hasSearchMatches`: the active search produced at least one result. Only consulted when a
    ///   search is active.
    static func select(
        storeHasNotes: Bool,
        searchActive: Bool,
        hasSearchMatches: Bool
    ) -> FolderScreenState {
        guard storeHasNotes else { return .emptyStore }
        guard searchActive else { return .normal }
        return hasSearchMatches ? .searchResults : .noMatches
    }

    /// Whether the persistent search field is shown in this state. It hides only in the truly empty
    /// store (nothing to search); in every other state - including "no matches" - it stays visible so
    /// the user can refine or clear the query.
    var showsSearchField: Bool {
        self != .emptyStore
    }
}
