import Foundation

/// Pure layout-decision logic for the search + bottom-bar redesign (spec 0021), factored out of the
/// SwiftUI views so the state selection and the "which right-side actions" choice are unit-testable
/// rather than trapped in view `body`.

/// Which content state a list/folder screen shows, given whether the whole store is empty, whether a
/// search is active, and whether that search found anything. The view renders one of these; the mapping
/// from raw conditions to the case lives here so it can be tested exhaustively.
enum FolderScreenState: Equatable {
    /// The store has no thoughts at all: show the centered record + new-thought CTA (spec 0021 empty state).
    /// The search field hides in this state (nothing to search).
    case emptyStore
    /// A search is active and matched at least one thought: show the flat global results list.
    case searchResults
    /// A search is active but matched nothing in a non-empty store: show a "no matches" message, keeping
    /// the search field visible so the user can edit the query.
    case noMatches
    /// No active search: show the normal interleaved folder list (folders + thoughts at this path).
    case normal

    /// Select the state.
    ///
    /// - `storeHasThoughts`: the whole store has at least one thought (across all folders). When false, the
    ///   screen is `.emptyStore` regardless of search - there is nothing to find.
    /// - `searchActive`: the search field has a non-whitespace query (see `ThoughtSearch.isActive`).
    /// - `hasSearchMatches`: the active search produced at least one result. Only consulted when a
    ///   search is active.
    static func select(
        storeHasThoughts: Bool,
        searchActive: Bool,
        hasSearchMatches: Bool
    ) -> FolderScreenState {
        guard storeHasThoughts else { return .emptyStore }
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

/// Which affordances the THOUGHT-DETAIL bottom bar shows (spec 0021), and whether it shows at all. The
/// thought page's bar carries a search field and a resume icon, and it must be HIDDEN entirely while the
/// user edits the title or body (engineer + architect review): otherwise the search `TextField` renders
/// under the keyboard during an edit, and a brand-new (`.newThought`) thought shows two competing text fields
/// from open. This pure decision lives here (mirroring `FolderScreenState`) so it is unit-tested, not
/// re-derived inline in the view.
struct ThoughtDetailBottomBar: Equatable {
    /// Whether to show the bar at all. False while editing (the Done flow owns the screen).
    let isVisible: Bool
    /// Whether the search field is shown (a call site that enables in-thought find, spec 0025).
    let showsSearch: Bool
    /// Whether the resume icon is shown (a call site that can reopen a session, resuming applies per the
    /// audio-retention setting, and the thought is not a still-empty brand-new draft).
    let showsResume: Bool

    /// Decide what the thought-detail bottom bar shows.
    ///
    /// - `canSearch`: the call site enables the in-thought find field (else no field, spec 0025).
    /// - `canResume`: a call site supplied `onResume` (else no resume icon).
    /// - `resumeApplies`: the audio-retention setting makes resuming meaningful for this thought.
    /// - `isEditing`: the title OR body editor is active - the bar is hidden entirely while true.
    /// - `isUnsavedNewThought`: a brand-new thought with no committed content - no resume onto it yet.
    static func decide(
        canSearch: Bool,
        canResume: Bool,
        resumeApplies: Bool,
        isEditing: Bool,
        isUnsavedNewThought: Bool
    ) -> ThoughtDetailBottomBar {
        // Hidden entirely while editing, so the search field never renders under the keyboard and a new
        // thought does not present two competing text fields.
        if isEditing {
            return ThoughtDetailBottomBar(isVisible: false, showsSearch: false, showsResume: false)
        }
        let showsResume = canResume && resumeApplies && !isUnsavedNewThought
        // The bar is worth showing only when at least one affordance would appear.
        let isVisible = canSearch || showsResume
        return ThoughtDetailBottomBar(isVisible: isVisible, showsSearch: canSearch, showsResume: showsResume)
    }
}
