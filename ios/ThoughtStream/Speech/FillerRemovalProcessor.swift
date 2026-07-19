import Foundation

/// A `TextProcessor` that removes standalone hesitation ("filler") tokens from committed dictation
/// text (spec 0016), so a saved note reads like written notes without changing what the user said in
/// substance. Only ever runs on DICTATION text: `CompositeTextProcessor` composes it AFTER the Mira
/// command split and spelling overrides, so it never touches the command portion of a segment.
///
/// The removed set is deliberately CONSERVATIVE (whole tokens only, case-insensitive):
///
///     um, umm, uh, uhh, erm, hmm, mm, mmm, er, ah, uh-huh
///
/// These are pure hesitation sounds with no dictionary meaning, so stripping one never changes what a
/// sentence says. Risky words that are OFTEN meaningful - "like", "so", "you know", "yeah", "right" -
/// are INTENTIONALLY NOT in the set: a false positive there silently changes meaning ("I like it" ->
/// "I it", "so we shipped" -> "we shipped"), which is worse than leaving a filler in. Leaving a real
/// filler is a cosmetic miss; deleting a real word is a content error, so the default errs toward
/// under-removal. A later milestone can add an opt-in "aggressive" list if wanted (spec 0016 non-goal).
///
/// Whole-token matching is what keeps "I am hungry" and "a hummingbird" safe: "am"/"ah"/"um" are only
/// removed when they are a COMPLETE token, never a run inside a longer word. After removal the
/// processor collapses the whitespace and dangling punctuation a removed filler leaves behind
/// ("So, um, yeah" -> "So, yeah") and re-capitalizes a sentence whose leading filler was stripped
/// ("um the plan" -> "The plan"). If removal empties the segment (it was nothing but fillers), it
/// resolves to `.drop` so the view model creates no empty paragraph and does not advance the
/// paragraph grouper (feedback 0012 coupling; see `DictationViewModel.handleFinalized`).
struct FillerRemovalProcessor: TextProcessor {
    /// The conservative default hesitation set, lowercased for case-insensitive whole-token matching.
    /// See the type doc for why the "risky" words are excluded.
    static let defaultFillers: Set<String> = [
        "um", "umm", "uh", "uhh", "erm", "hmm", "mm", "mmm", "er", "ah", "uh-huh",
    ]

    private let fillers: Set<String>

    init(fillers: Set<String> = FillerRemovalProcessor.defaultFillers) {
        self.fillers = Set(fillers.map { $0.lowercased() })
    }

    func process(_ text: String) -> ProcessedSegment {
        let cleaned = removeFillers(from: text)
        // A segment that was nothing but fillers (and now empty) is DROPPED, not committed as an empty
        // paragraph. `.drop` also keeps the paragraph grouper's anchor where the last real text left it
        // (the view model never calls `grouper.decide` for a `.drop`), so a filler-only breath cannot
        // shift a following paragraph boundary.
        if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .drop
        }
        return .text(cleaned)
    }

    /// Matches a word token, allowing an internal hyphen so "uh-huh" is one token (and so a real
    /// hyphenated word like "well-being" is matched whole and never partially stripped). A token is a
    /// letter/number run, optionally joined by single hyphens to more letter/number runs.
    private static let tokenRegex = try! NSRegularExpression(
        pattern: "[\\p{L}\\p{N}]+(?:-[\\p{L}\\p{N}]+)*"
    )

    /// Remove standalone filler tokens, then tidy the spacing, dangling punctuation, and leading
    /// capitalization the removals leave behind.
    private func removeFillers(from text: String) -> String {
        let ns = text as NSString
        let matches = Self.tokenRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let result = NSMutableString(string: text)
        // Whether the FIRST token of the segment was a filler that gets removed. Only in that case is
        // the following word promoted to the start of the sentence, so only then do we re-capitalize -
        // a segment with no leading filler keeps the user's own casing verbatim.
        var removedLeadingFiller = false
        if let firstToken = matches.first {
            removedLeadingFiller = fillers.contains(ns.substring(with: firstToken.range).lowercased())
        }
        // Walk matches from the END so an earlier match's range stays valid after a later token is
        // deleted (deletions shift everything after them).
        for match in matches.reversed() {
            let token = ns.substring(with: match.range)
            if fillers.contains(token.lowercased()) {
                result.replaceCharacters(in: match.range, with: "")
            }
        }
        return Self.tidy(result as String, recapitalizeLeading: removedLeadingFiller)
    }

    /// Collapse the whitespace and dangling punctuation a removed filler leaves behind, and (only when
    /// `recapitalizeLeading` is set, i.e. a leading filler was stripped) re-capitalize the new first
    /// word. Pure string cleanup, no token logic.
    static func tidy(_ text: String, recapitalizeLeading: Bool) -> String {
        var s = text

        // Collapse any run of horizontal whitespace to a single space FIRST (leave newlines alone so a
        // deliberate paragraph break survives). Doing this before the punctuation passes below keeps
        // those patterns matching a bounded single space rather than an unbounded `\s+` run - a long
        // whitespace run through `\s+([,.;:!?])` backtracks quadratically (security review), and there
        // is nothing to gain from letting it.
        s = s.replacingOccurrences(
            of: "[ \\t]+", with: " ", options: .regularExpression
        )
        // Drop the (now single) space that sits directly before punctuation ("So , yeah" -> "So, yeah").
        s = s.replacingOccurrences(
            of: " ([,.;:!?])", with: "$1", options: .regularExpression
        )
        // Collapse a run of duplicated separators a removal produced (", ," -> ",") into the first.
        s = s.replacingOccurrences(
            of: "([,;:])( ?[,;:])+", with: "$1", options: .regularExpression
        )
        // A comma/semicolon/colon left ABUTTING a terminal mark ("So, um. yeah" -> "So,. yeah")
        // collapses to just the terminal mark ("So. yeah"). The `[,;:]` collapse above misses this
        // because a terminal mark is not in that class.
        s = s.replacingOccurrences(
            of: "[,;:]+([.!?])", with: "$1", options: .regularExpression
        )
        // Drop leading punctuation/space a stripped leading filler left ("  , the plan" -> "the plan").
        s = s.replacingOccurrences(
            of: "^[\\s,;:.!?]+", with: "", options: .regularExpression
        )
        // Trim trailing whitespace (a stripped trailing filler can leave one).
        s = s.trimmingCharacters(in: .whitespaces)

        guard recapitalizeLeading else { return s }
        return capitalizeLeading(s)
    }

    /// Upper-case the first alphabetic character of the string, so a sentence whose leading filler was
    /// removed ("um the plan" -> "the plan" -> "The plan") reads as a proper sentence again. Only the
    /// FIRST letter is touched; the rest of the casing (including proper nouns downstream) is left as
    /// the user said it.
    ///
    /// A promoted first WORD that already carries an interior capital ("iPhone", "eBay", "iOS") is left
    /// untouched: re-casing it ("IPhone") would corrupt an intentionally-cased brand, exactly the kind
    /// of silent content change the conservative posture avoids. Only an all-lowercase lead is fixed.
    private static func capitalizeLeading(_ text: String) -> String {
        guard let first = text.firstIndex(where: { $0.isLetter }) else { return text }
        let word = text[first...].prefix { !$0.isWhitespace }
        guard !word.dropFirst().contains(where: { $0.isUppercase }) else { return text }
        let upper = text[first].uppercased()
        return text.replacingCharacters(in: first...first, with: upper)
    }
}
