import Foundation

/// A text -> text `TextProcessor` that applies the user's spelling overrides to dictated text.
///
/// Matching is whole-word and case-insensitive: a standalone word whose lowercased form equals an
/// override's lowercased `from` is replaced with that override's `to`, written as the user typed
/// it. Whole-word so a "Shay" -> "Shea" override never touches "Shayla" or a substring; only a
/// complete token matches. Always returns `.text` - it never recognizes commands.
///
/// Composed after the command processor (see `CompositeTextProcessor`) so a control phrase is
/// never spelling-mangled.
struct SpellingOverrideProcessor: TextProcessor {
    /// Lowercased `from` -> replacement `to`. First override in the ordered list wins on a
    /// duplicate `from`. A row is active only when BOTH sides are non-blank, so a half-typed row
    /// does nothing. Requiring a non-blank `to` matters: a blank `to` would silently DELETE every
    /// occurrence of the spoken word (the opposite of a spelling fix), and the Settings "Add
    /// override" flow persists exactly such an empty row.
    private let map: [String: String]

    /// Matches a run of word characters. Only complete matches are considered for replacement, so
    /// substrings inside a longer word are never touched.
    private static let wordRegex = try! NSRegularExpression(pattern: "\\w+")

    init(overrides: [SpellingOverride]) {
        var map: [String: String] = [:]
        for override in overrides {
            let key = override.from.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = override.to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty, map[key] == nil else { continue }
            map[key] = value
        }
        self.map = map
    }

    func process(_ text: String) -> ProcessedSegment {
        .text(apply(to: text))
    }

    /// Replace each whole word whose lowercased form is an override key. Walks matches from the end
    /// so an earlier match's range stays valid after a later one is replaced (replacements can
    /// change length). Editing an `NSMutableString` by NSRange keeps the offsets unambiguous.
    private func apply(to text: String) -> String {
        guard !map.isEmpty else { return text }
        let ns = text as NSString
        let matches = Self.wordRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            let word = ns.substring(with: match.range)
            if let replacement = map[word.lowercased()] {
                result.replaceCharacters(in: match.range, with: replacement)
            }
        }
        return result as String
    }
}
