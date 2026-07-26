import Foundation

/// Pure, deterministic tidying of an already-split transcript (spec 0016). New recordings are
/// flow-grouped at capture time (feedback 0012), but text that was typed, edited, or loaded from an
/// older thought can still have a single sentence split across paragraphs. `reflow` merges the obvious
/// continuation cases and nothing else.
///
/// It is applied only when the refine setting is on AND a thought is saved after an EDIT (the composition
/// root's `StreamListView` calls `refinedForSave(_:refine:)` on the `onCommitEdit` save path;
/// `ThoughtDetailView` only emits the intent and stays presentational), never on load - so an untouched
/// old thought is not silently rewritten until the user edits it. Both the merge rule (`reflow`) and the
/// on-save gating (`refinedForSave`) are pure so they are unit-tested without the view.
enum TranscriptCleanup {
    /// The Thought to persist on an edit-save (spec 0016), gated by the refine flag. This is the SINGLE
    /// enforcement point for "reflow on edit-save when refine is on, and NEVER on load": callers hand
    /// it the edited thought plus the current `refineTranscript` setting.
    ///
    /// - `refine == false` -> the thought is returned VERBATIM (no reflow), preserving today's behavior.
    /// - `refine == true` -> paragraphs are `reflow`-merged; if reflow changed nothing the SAME thought is
    ///   returned unchanged (a thought with no continuations is byte-identical, so a re-save is a no-op),
    ///   otherwise a rebuilt copy via `Thought.editedCopy` preserving title, recording, timings, and folder.
    ///
    /// Load paths never call this, so a thought is refined only when the user edits and saves it - an
    /// untouched loaded thought is never silently rewritten.
    static func refinedForSave(_ thought: Thought, refine: Bool) -> Thought {
        guard refine else { return thought }
        let reflowed = reflow(thought.paragraphs)
        guard reflowed != thought.paragraphs else { return thought }
        return thought.editedCopy(
            paragraphs: reflowed,
            hasCustomTitle: thought.hasCustomTitle,
            customTitle: thought.title
        )
    }

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
    ///
    /// KNOWN TRADE-OFF (engineer review): a dictated list whose items are adjacent lowercase paragraphs
    /// with no terminal punctuation ("Buy milk" / "eggs and bread") MERGES into one line by design -
    /// that is exactly the continuation rule, and the transcript layer cannot tell a run-on sentence
    /// from an intended list. The escape hatch is the same signal a user already has: a DELIBERATE blank
    /// line between items survives (it makes them separate paragraphs the rule leaves alone), and a
    /// capitalized or terminated item is never merged. Adjacent lowercase continuations merging is the
    /// accepted behavior, not a bug.
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
