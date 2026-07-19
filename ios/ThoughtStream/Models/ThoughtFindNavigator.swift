import Foundation

/// The pure navigation + count state over an in-thought find's match list (spec 0025), factored out of the
/// SwiftUI detail view so the current-match index math, the "N of M" count formatting, and the mapping of a
/// match's region to a stable scroll-anchor id are all unit-testable rather than trapped in view `body`.
///
/// Navigation WRAPS (documented choice): next past the last match goes to the first, previous before the
/// first goes to the last. A fresh navigator over a non-empty match list starts on the first match (index
/// 0); over an empty list it has no current match and an empty count.
struct ThoughtFindNavigator: Equatable {
    /// The ordered matches this navigator steps through (from `ThoughtFind.matches`).
    let matches: [ThoughtFind.Match]
    /// The current match index into `matches`, or nil when there are no matches.
    private(set) var currentIndex: Int?

    /// Build a navigator, starting on the FIRST match when there is one (so a find seeks to the first hit),
    /// or with no current match when the list is empty.
    init(matches: [ThoughtFind.Match]) {
        self.matches = matches
        self.currentIndex = matches.isEmpty ? nil : 0
    }

    /// The current match, or nil when there are no matches.
    var currentMatch: ThoughtFind.Match? {
        guard let currentIndex else { return nil }
        return matches[currentIndex]
    }

    /// Whether there is at least one match (the prev/next/count affordance shows only then).
    var hasMatches: Bool { !matches.isEmpty }

    /// Advance to the next match, WRAPPING from the last back to the first. A no-op when there are no matches.
    mutating func next() {
        guard let currentIndex, !matches.isEmpty else { return }
        self.currentIndex = (currentIndex + 1) % matches.count
    }

    /// Step to the previous match, WRAPPING from the first back to the last. A no-op when there are no matches.
    mutating func previous() {
        guard let currentIndex, !matches.isEmpty else { return }
        self.currentIndex = (currentIndex - 1 + matches.count) % matches.count
    }

    /// The "N of M" count shown beside the find field (1-based), or an empty string when there are no
    /// matches (the affordance is hidden then, so the string is never read - kept empty rather than "0 of 0").
    var countLabel: String {
        guard let currentIndex, !matches.isEmpty else { return "" }
        return "\(currentIndex + 1) of \(matches.count)"
    }
}

extension ThoughtFind.Region {
    /// A STABLE scroll-anchor id for this region, so `ScrollViewReader` can seek the current match into view.
    /// The title anchors on one id; each paragraph anchors on its index. Kept here (not in the view) so the
    /// match -> anchor mapping is unit-tested alongside the navigation.
    var scrollID: String {
        switch self {
        case .title:
            return "find.title"
        case let .paragraph(index):
            return "find.paragraph.\(index)"
        }
    }
}
