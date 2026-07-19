import Foundation

/// Full-text thought search (spec 0021), factored as a PURE, unit-testable function over the thoughts the
/// store already loads - no separate index. A thought matches when its TITLE or ANY of its body
/// paragraphs contains the query as a substring, case-insensitively AND diacritic-insensitively
/// ("cafe" finds "cafe" and "cafe" with an accent, "PLAN" finds "plan").
///
/// Search is GLOBAL across the whole folder tree: `results(in:query:)` scans every loaded thought
/// regardless of `folderPath` and returns a flat, newest-first list, so a match in any folder surfaces.
/// Keeping the match logic here (not in the SwiftUI view) means the among-folder behavior, the
/// normalization, and the empty-query semantics are all provable without UI.
enum ThoughtSearch {
    /// A trimmed query is "active" (should drive results) only when it has non-whitespace content. An
    /// empty or whitespace-only field restores the normal folder view, so the view keys its
    /// results-vs-normal decision on this rather than on `text.isEmpty` (which a lone space would fool).
    static func isActive(_ rawQuery: String) -> Bool {
        !normalized(rawQuery).isEmpty
    }

    /// Whether `thought` matches `rawQuery`: the normalized query is a substring of the thought's normalized
    /// title or any normalized paragraph. An empty/whitespace query matches EVERYTHING (so callers that
    /// pass it through get the full list back), matching the "clearing the field restores the view"
    /// contract when the caller does not gate on `isActive` first.
    static func matches(_ thought: Thought, query rawQuery: String) -> Bool {
        matches(thought, needle: normalized(rawQuery))
    }

    /// The flat, global result list for `rawQuery` across `thoughts`, preserving the input order (the store
    /// hands thoughts newest first, so results stay newest first). An empty/whitespace query returns the
    /// thoughts unchanged, so a caller can treat "no query" and "query matches all" uniformly. Thoughts from
    /// any folder are eligible - this never filters by `folderPath`.
    ///
    /// The query is FOLDED ONCE here (not per thought): folding the needle inside `matches` on every thought
    /// would re-normalize the same query N times per search (architect review). Each thought's title and
    /// paragraphs still fold per candidate, which is inherent to a substring search over the loaded text.
    static func results(in thoughts: [Thought], query rawQuery: String) -> [Thought] {
        let needle = normalized(rawQuery)
        if needle.isEmpty { return thoughts }
        return thoughts.filter { matches($0, needle: needle) }
    }

    /// Whether `thought` matches an ALREADY-folded needle. `needle` must be pre-normalized (see
    /// `normalized`); an empty needle matches everything. Shared by `matches(_:query:)` and `results` so
    /// the query is folded once per search, not once per thought.
    private static func matches(_ thought: Thought, needle: String) -> Bool {
        if needle.isEmpty { return true }
        if normalized(thought.title).contains(needle) { return true }
        return thought.paragraphs.contains { normalized($0).contains(needle) }
    }

    /// Fold a string to the comparison form: lowercased and stripped of diacritics/case using a
    /// locale-aware, case- and diacritic-insensitive fold, then trimmed of surrounding whitespace. Two
    /// strings that differ only in case or accents fold to the same value, so a substring test on the
    /// folded forms is case- and diacritic-insensitive. Kept private so every match goes through the
    /// one normalization.
    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
