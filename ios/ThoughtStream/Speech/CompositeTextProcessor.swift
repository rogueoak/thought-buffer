import Foundation

/// Composes the Mira command processor with the spelling-override processor, in that order.
///
/// ORDER MATTERS. A finalized segment is checked for a command FIRST, on the RAW text, so a
/// control phrase is never spelling-mangled (and the phrase is suppressed from the note anyway).
/// Only if the segment is not a command does it flow through the spelling processor and commit as
/// `.text`. This is the seam spec 0003 left open and spec 0006 fills.
///
/// Built per dictation session from current settings (see `AppDependencies.makeTextProcessor`), so
/// edits in Settings take effect on the next session, not one already running.
struct CompositeTextProcessor: TextProcessor {
    private let command: MiraTextProcessor
    private let spelling: SpellingOverrideProcessor

    init(controlWord: String, overrides: [SpellingOverride]) {
        self.command = MiraTextProcessor(controlWord: controlWord)
        self.spelling = SpellingOverrideProcessor(overrides: overrides)
    }

    func process(_ text: String) -> ProcessedSegment {
        // Detect a command on the raw segment first; a command is returned untouched.
        let commandResult = command.process(text)
        if case .command = commandResult {
            return commandResult
        }
        // Not a command: apply spelling overrides to the dictated text.
        return spelling.process(text)
    }
}
