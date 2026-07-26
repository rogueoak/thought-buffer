import Foundation

/// Validation for the assistant control phrase, kept as a neutral seam (not tied to any concrete
/// store) so both `SettingsStoring` implementations and the Settings UI share one rule.
///
/// The `MiraCommandParser` matches the control word as a SINGLE leading token, tokenizing on
/// non-alphanumerics. So a stored phrase must reduce to exactly one alphanumeric word, or every
/// command would silently stop firing. Validation therefore:
///
/// - trims whitespace,
/// - keeps only the FIRST alphanumeric token (so "Hey Nova" -> "Hey", "Mira!" -> "Mira"), and
/// - falls back to the default word ("Mira") when the result is empty or over the length cap.
enum ControlPhrase {
    /// The default assistant control word. Lives here (not in `MiraTextProcessor`) so the layering
    /// runs one way: the Settings seam owns the validation rule and its fallback, and the speech
    /// processor references THIS rather than the other way around.
    static let defaultWord = "Mira"

    /// A sensible upper bound. A name longer than this is almost certainly a mistake (or a whole
    /// sentence pasted in), so it falls back to the default rather than making every command start
    /// with a paragraph.
    static let maxLength = 32

    /// The default alias set for the default word "Mira" (spec 0018): common recognizer mishearings,
    /// so a fresh install already tolerates them. The user can add or remove aliases. Excludes the
    /// primary word itself ("mira") because an alias never duplicates the primary word (the primary
    /// is always a trigger via `triggerWords`, and `validatedAliases` would drop a "mira" alias as a
    /// collision anyway).
    static let defaultAliases = ["mirra", "meera", "mirror"]

    /// Validate a raw phrase to what the parser can actually match. Pure, so the store, the view,
    /// and tests all share it.
    static func validated(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The parser matches a single leading token split on non-alphanumerics; keep the first such
        // token so a multi-word or punctuated phrase can never silently disable all commands.
        let firstToken = trimmed
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .first
            .map(String.init) ?? ""
        guard !firstToken.isEmpty, firstToken.count <= maxLength else {
            return defaultWord
        }
        return firstToken
    }

    /// Reduce a raw alias to the single token the parser can match, or nil when it is not usable.
    /// Same token contract as `validated` (trim, length cap), but an alias must be a SINGLE token and
    /// a bad one is DROPPED (nil), not defaulted - an alias list may legitimately be empty, whereas
    /// the primary word must always resolve to something. A multi-word entry is rejected rather than
    /// silently reduced to its first word, so the UI can tell the user it was not accepted. Casing is
    /// preserved for display; the parser lowercases it when matching.
    static func validatedAlias(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = trimmed.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard tokens.count == 1, let token = tokens.first, token.count <= maxLength else {
            return nil
        }
        return token
    }

    /// Validate an ordered raw alias list against a primary word: keep only single-token aliases,
    /// de-duplicated case-insensitively, and never colliding with the primary word (an alias cannot
    /// shadow the primary word). Preserves the first occurrence's order and casing. Pure, so the
    /// store, the view, and tests share it.
    static func validatedAliases(_ raw: [String], primaryWord: String) -> [String] {
        let primaryKey = validated(primaryWord).lowercased()
        var seen: Set<String> = [primaryKey]
        var result: [String] = []
        for entry in raw {
            guard let token = validatedAlias(entry) else { continue }
            let key = token.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(token)
        }
        return result
    }

    /// The full, ordered set of trigger words the parser matches: the primary control word FIRST,
    /// then the validated aliases. Single point that assembles "primary + aliases" so the factory and
    /// tests never re-derive it; the primary word always leads and can never be removed or shadowed.
    static func triggerWords(primaryWord: String, aliases: [String]) -> [String] {
        [validated(primaryWord)] + validatedAliases(aliases, primaryWord: primaryWord)
    }
}
