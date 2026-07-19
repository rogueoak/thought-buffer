import SwiftUI

/// The iPad-adaptivity CONTAINER decision (spec 0022), kept in its own SwiftUI-importing file because it
/// depends on `UserInterfaceSizeClass`. The SwiftUI-free search/state projection (`StreamSearchProjection`)
/// lives beside it in a UI-free file so a future Watch target can reuse it (architect review).

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

    /// Whether a folder SCREEN renders its OWN bottom stack (search field + record actions + now-playing +
    /// undo chip) in this container (spec 0022 single-bottom-bar invariant, factored to a tested seam). In
    /// the COMPACT stack one folder screen is on-screen at a time, so it owns its bar (true). In the SPLIT
    /// view the sidebar and content columns are both folder screens at once, so neither owns a bar - the
    /// container lifts ONE shared bar above them (false). Deriving this from the container (rather than a
    /// raw `showsBottomBar:` literal at each call site) means a future edit cannot accidentally give a split
    /// column its own bar - reintroducing two fields fighting one state - or drop the iPhone bar.
    var folderScreenShowsOwnBottomBar: Bool {
        switch self {
        case .stack: return true
        case .split: return false
        }
    }

    /// Whether the THOUGHT DETAIL screen hosts the shared bottom PLAYER in its own bottom inset (feedback
    /// 0027). In the COMPACT stack a `NavigationStack` push swaps the pushing screen's `safeAreaInset`, so
    /// the pushed detail must re-host the one shared `BottomPlayer` (true) or the transport vanishes on the
    /// thought page. In the SPLIT view the player is LIFTED above all columns once
    /// (`StreamListView.liftedBottomStack`), so the detail column must NOT host it (false) or it double-
    /// renders. Deriving this from the container - the SAME seam `folderScreenShowsOwnBottomBar` uses - keeps
    /// "who hosts the player" a SINGLE tested decision, so a future lifting container cannot silently
    /// double-render by a call site forgetting to pass a flag.
    var detailHostsBottomPlayer: Bool {
        switch self {
        case .stack: return true
        case .split: return false
        }
    }
}
