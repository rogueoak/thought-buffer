import Foundation

/// Full-text note search (spec 0021), factored as a PURE, unit-testable function over the notes the
/// store already loads - no separate index. A note matches when its TITLE or ANY of its body
/// paragraphs contains the query as a substring, case-insensitively AND diacritic-insensitively
/// ("cafe" finds "cafe" and "cafe" with an accent, "PLAN" finds "plan").
///
/// Search is GLOBAL across the whole folder tree: `results(in:query:)` scans every loaded note
/// regardless of `folderPath` and returns a flat, newest-first list, so a match in any folder surfaces.
/// Keeping the match logic here (not in the SwiftUI view) means the among-folder behavior, the
/// normalization, and the empty-query semantics are all provable without UI.
enum NoteSearch {
    /// A trimmed query is "active" (should drive results) only when it has non-whitespace content. An
    /// empty or whitespace-only field restores the normal folder view, so the view keys its
    /// results-vs-normal decision on this rather than on `text.isEmpty` (which a lone space would fool).
    static func isActive(_ rawQuery: String) -> Bool {
        !normalized(rawQuery).isEmpty
    }

    /// Whether `note` matches `rawQuery`: the normalized query is a substring of the note's normalized
    /// title or any normalized paragraph. An empty/whitespace query matches EVERYTHING (so callers that
    /// pass it through get the full list back), matching the "clearing the field restores the view"
    /// contract when the caller does not gate on `isActive` first.
    static func matches(_ note: Note, query rawQuery: String) -> Bool {
        let needle = normalized(rawQuery)
        if needle.isEmpty { return true }
        if normalized(note.title).contains(needle) { return true }
        return note.paragraphs.contains { normalized($0).contains(needle) }
    }

    /// The flat, global result list for `rawQuery` across `notes`, preserving the input order (the store
    /// hands notes newest first, so results stay newest first). An empty/whitespace query returns the
    /// notes unchanged, so a caller can treat "no query" and "query matches all" uniformly. Notes from
    /// any folder are eligible - this never filters by `folderPath`.
    static func results(in notes: [Note], query rawQuery: String) -> [Note] {
        let needle = normalized(rawQuery)
        if needle.isEmpty { return notes }
        return notes.filter { matches($0, query: rawQuery) }
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
