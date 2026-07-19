import Foundation

/// In-thought find (spec 0025): the pure, unit-testable core that locates a query WITHIN one thought's
/// title and body paragraphs and drives seek / highlight / skip. This is the per-thought counterpart to
/// `ThoughtSearch` (spec 0021, which decides WHICH thoughts match, globally): where `ThoughtSearch`
/// returns matching thoughts, `ThoughtFind` returns the ordered MATCH LOCATIONS inside a single thought so
/// the detail view can highlight and scroll to each one.
///
/// Matching reuses `ThoughtSearch`'s folding contract - case-insensitive AND diacritic-insensitive
/// substring - but folds PER CHARACTER so each match's character range maps back to the ORIGINAL text
/// (the view highlights ranges of the rendered string, so a length-changing fold would misplace the
/// highlight). An empty or whitespace-only query yields no matches.
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

    /// One located match: its region and the character range within that region's ORIGINAL text. The range
    /// is a `Range<String.Index>` into the region's string (the title or the paragraph at `paragraph(i)`),
    /// so the view can build an `AttributedString` highlight directly from it.
    struct Match: Equatable {
        let region: Region
        let range: Range<String.Index>
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
        result.append(contentsOf: rangesOf(needle, in: title).map { Match(region: .title, range: $0) })
        for (index, paragraph) in paragraphs.enumerated() {
            result.append(contentsOf: rangesOf(needle, in: paragraph).map { Match(region: .paragraph(index), range: $0) })
        }
        return result
    }

    /// Every range in `haystack` where the folded haystack contains the already-folded `needle`, left to
    /// right, non-overlapping. `needle` must be non-empty. Both sides fold PER CHARACTER (so a fold that
    /// changes length cannot shift indices): a folded character keeps a 1:1 map to its source `Character`,
    /// so a run of `needle.count` consecutive folded haystack characters maps straight back to a range of
    /// the ORIGINAL `haystack`.
    private static func rangesOf(_ needle: [String], in haystack: String) -> [Range<String.Index>] {
        if needle.isEmpty { return [] }
        // Fold each character, keeping its original index alongside so a match window maps back to a range.
        let folded: [(index: String.Index, value: String)] = haystack.indices.map { idx in
            (idx, fold(haystack[idx]))
        }
        // A folded character can be empty (a lone combining mark folds away): it cannot start or belong to a
        // match, so skip empties when comparing but still let the window advance past them.
        var result: [Range<String.Index>] = []
        var start = 0
        while start <= folded.count - needle.count {
            if windowMatches(folded, at: start, needle: needle) {
                let lower = folded[start].index
                let upperCharIndex = start + needle.count - 1
                let upper = haystack.index(after: folded[upperCharIndex].index)
                result.append(lower..<upper)
                // Non-overlapping: continue past this match so "aa" in "aaa" yields one match, not two.
                start += needle.count
            } else {
                start += 1
            }
        }
        return result
    }

    /// Whether `needle` matches the folded haystack starting at character `start`, character by character.
    private static func windowMatches(_ folded: [(index: String.Index, value: String)], at start: Int, needle: [String]) -> Bool {
        for offset in 0..<needle.count where folded[start + offset].value != needle[offset] {
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

    /// Fold one character to its case- and diacritic-insensitive form, matching `ThoughtSearch`'s folding
    /// options so the two search seams agree on what "matches". A character whose fold is empty (a combining
    /// mark that folds away) returns "".
    private static func fold(_ character: Character) -> String {
        String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
