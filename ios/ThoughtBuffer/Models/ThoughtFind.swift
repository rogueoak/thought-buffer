import Foundation

/// In-thought find (spec 0025): the pure, unit-testable core that locates a query WITHIN one thought's
/// title and body paragraphs and drives seek / highlight / skip. This is the per-thought counterpart to
/// `ThoughtSearch` (spec 0021, which decides WHICH thoughts match, globally): where `ThoughtSearch`
/// returns matching thoughts, `ThoughtFind` returns the ordered MATCH LOCATIONS inside a single thought so
/// the detail view can highlight and scroll to each one.
///
/// Matching reuses `ThoughtSearch`'s folding OPTIONS (one shared `foldingOptions` constant) - case- AND
/// diacritic-insensitive substring - but folds PER CHARACTER so each match's character range maps back to
/// the ORIGINAL text (the view highlights ranges of the rendered string, so a length-changing whole-string
/// fold would misplace the highlight). The two AGREE for length-preserving folds (case, most accents) and
/// DIVERGE only for the rare length-changing fold (a ligature, German 'sz' -> 'ss'), where a thought can
/// surface in the global search yet show no in-thought match - a deliberate cost of range preservation,
/// documented on `fold`. An empty or whitespace-only query yields no matches.
///
/// No SwiftUI import: the ordering, the ranges, next/previous navigation (wrapping), and the "N of M"
/// count are all provable without UI. The detail view is a thin caller that maps a `Match` to a highlight
/// range and a scroll anchor.
enum ThoughtFind {
    /// Which addressable region of a thought a match sits in: the TITLE, or a body paragraph by index.
    /// The detail view anchors a stable scroll id off this (`FindRegion.scrollID`) and picks the string to
    /// highlight from it.
    enum Region: Equatable {
        case title
        case paragraph(Int)
    }

    /// One located match: its region and the CHARACTER-OFFSET range within that region's ORIGINAL text -
    /// `characterRange.lowerBound..<upperBound` counted in `Character`s (grapheme clusters) from the region
    /// string's start. Integer offsets rather than `String.Index` on purpose: a `String.Index` is only valid
    /// against the exact string instance that produced it, and the view re-derives `currentThought.title`
    /// each render (a fresh instance), so reusing a stored `String.Index` against it is undefined for
    /// non-ASCII text (engineer review). Character offsets are instance-independent: the view resolves them
    /// against whatever region string it holds (`AttributedString.index(_:offsetByCharacters:)`), and they
    /// map 1:1 to the source because folding is per character (see `rangesOf`).
    struct Match: Equatable {
        let region: Region
        let characterRange: Range<Int>
    }

    /// The ordered list of every match of `query` in the thought's `title` then its `paragraphs` (in
    /// order), left to right within each region. An empty / whitespace-only query returns no matches
    /// (see `ThoughtSearch.isActive`). Case- and diacritic-insensitive substring, folded per character so
    /// each range indexes the original region text.
    static func matches(title: String, paragraphs: [String], query: String) -> [Match] {
        let needle = foldedCharacters(query)
        // A query that folds to nothing (empty or whitespace/diacritic-only) matches nothing: an in-thought
        // find with no query shows no highlights, mirroring `ThoughtSearch.isActive`.
        if needle.isEmpty { return [] }
        var result: [Match] = []
        result.append(contentsOf: rangesOf(needle, in: title).map { Match(region: .title, characterRange: $0) })
        for (index, paragraph) in paragraphs.enumerated() {
            result.append(contentsOf: rangesOf(needle, in: paragraph).map { Match(region: .paragraph(index), characterRange: $0) })
        }
        return result
    }

    /// The FIRST match of `query` in the thought (title first, then paragraphs in order), or nil when there
    /// is none (feedback 0030). This is the pure seam the detail view uses when a thought is opened FROM an
    /// active search: it carries the query in, and the first hit is where the in-note find seeks and
    /// highlights. Equivalent to `matches(...).first`, named so the "open from search seeks the first hit"
    /// behavior is unit-tested rather than trapped in the view.
    static func firstMatch(title: String, paragraphs: [String], query: String) -> Match? {
        matches(title: title, paragraphs: paragraphs, query: query).first
    }

    /// Every CHARACTER-OFFSET range in `haystack` where the folded haystack contains the already-folded
    /// `needle`, left to right, non-overlapping. `needle` must be non-empty. Both sides fold PER CHARACTER
    /// (so a fold that changes length cannot shift offsets): a folded character keeps a 1:1 map to its
    /// source `Character`, so a run of `needle.count` consecutive folded haystack characters maps straight
    /// back to a `[start, start + needle.count)` character range of the ORIGINAL `haystack`.
    private static func rangesOf(_ needle: [String], in haystack: String) -> [Range<Int>] {
        if needle.isEmpty { return [] }
        // Fold each character; its position IS its character offset (the array is built in `Character` order).
        let folded: [String] = haystack.map { fold($0) }
        // A folded character can be empty (a lone combining mark folds away): it cannot start or belong to a
        // match, so skip empties when comparing but still let the window advance past them.
        var result: [Range<Int>] = []
        var start = 0
        while start <= folded.count - needle.count {
            if windowMatches(folded, at: start, needle: needle) {
                result.append(start..<(start + needle.count))
                // Non-overlapping: continue past this match so "aa" in "aaa" yields one match, not two.
                start += needle.count
            } else {
                start += 1
            }
        }
        return result
    }

    /// Whether `needle` matches the folded haystack starting at character offset `start`, character by
    /// character.
    private static func windowMatches(_ folded: [String], at start: Int, needle: [String]) -> Bool {
        for offset in 0..<needle.count where folded[start + offset] != needle[offset] {
            return false
        }
        return true
    }

    /// Fold a query string to its per-character comparison form, dropping characters that fold away (a lone
    /// combining mark, whitespace is kept as itself so an intra-word space still has to match). Reused for
    /// both the needle and each haystack character so the two sides compare identically.
    private static func foldedCharacters(_ value: String) -> [String] {
        // Trim only the OUTER whitespace of the QUERY (a user typing " plan " means "plan"); interior
        // characters are folded as-is so the needle can still contain a space.
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.map { fold($0) }.filter { !$0.isEmpty }
    }

    /// The case- and diacritic-insensitive fold, the SAME options `ThoughtSearch` uses, hoisted to one
    /// constant so the two search seams cannot drift on the option set (architect review).
    static let foldingOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Fold one character to its case- and diacritic-insensitive form, matching `ThoughtSearch`'s folding
    /// OPTIONS. Note this folds PER CHARACTER where `ThoughtSearch` folds the whole string at once: the two
    /// AGREE for length-preserving folds (case, most accents), but DIVERGE for the rare length-changing fold
    /// (a ligature, German 'ss' from 'sz'), where a whole-string fold could match a substring a
    /// per-character fold does not - so a thought can surface in the GLOBAL search yet show no in-thought
    /// match for the same query. This is the deliberate cost of range preservation (a whole-string fold's
    /// offsets do not map back to the original), and it only bites unusual input. A character whose fold is
    /// empty (a combining mark that folds away) returns "".
    private static func fold(_ character: Character) -> String {
        String(character).folding(options: foldingOptions, locale: .current)
    }
}
