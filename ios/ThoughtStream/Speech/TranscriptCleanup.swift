import Foundation

/// Pure, deterministic tidying of an already-split transcript (spec 0016). New recordings are
/// flow-grouped at capture time (feedback 0012), but text that was typed, edited, or loaded from an
/// older note can still have a single sentence split across paragraphs. `reflow` merges the obvious
/// continuation cases and nothing else.
///
/// It is applied only when the refine setting is on AND a note is saved after an EDIT (wired at the
/// composition root in `StreamListView.refined(_:)` on the `onCommitEdit` save path; `NoteDetailView`
/// only emits the intent and stays presentational), never on load - so an untouched old note is not
/// silently rewritten until the user edits it. Kept pure (a `[String] -> [String]` on paragraphs) so
/// the merge rule is unit-tested without the view.
enum TranscriptCleanup {
    /// Merge obvious continuation lines: a paragraph that does NOT end in terminal punctuation, followed
    /// by a paragraph that BEGINS with a lowercase letter, is joined with a single space. Conservative:
    ///
    /// - It never SPLITS a paragraph, only merges adjacent ones.
    /// - It only merges when BOTH signals agree (no terminal punctuation before, lowercase start after),
    ///   so a finished sentence ("...the plan.") or a deliberate new thought ("The next step...") is
    ///   left alone.
    /// - A deliberately blank paragraph is impossible to reach here (the paragraph array carries no
    ///   empty entries), and a paragraph that already reads as a sentence is a natural break, so the
    ///   pass preserves user-intended breaks.
    /// - It is idempotent: running it on its own output changes nothing, because a merged paragraph
    ///   ends with whatever its last fragment ended with, and the merge test is re-evaluated left to
    ///   right against the growing result.
    static func reflow(_ paragraphs: [String]) -> [String] {
        var result: [String] = []
        for raw in paragraphs {
            let paragraph = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paragraph.isEmpty else { continue }
            if let previous = result.last, shouldMerge(previous: previous, next: paragraph) {
                result[result.count - 1] = previous + " " + paragraph
            } else {
                result.append(paragraph)
            }
        }
        return result
    }

    /// Whether `next` is a continuation of `previous`: `previous` does not end in terminal punctuation
    /// AND `next` begins with a lowercase letter. Both must hold, so an already-terminated sentence or a
    /// capitalized new thought is never merged.
    private static func shouldMerge(previous: String, next: String) -> Bool {
        guard let lastChar = previous.last, !isTerminal(lastChar) else { return false }
        guard let firstChar = next.first, firstChar.isLowercase else { return false }
        return true
    }

    /// Sentence-terminal punctuation. A paragraph ending in one of these reads as a finished sentence,
    /// so the following paragraph is a new one, not a continuation.
    private static func isTerminal(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?"
    }
}
