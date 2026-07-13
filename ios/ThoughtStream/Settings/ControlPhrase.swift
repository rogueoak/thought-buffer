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
}
