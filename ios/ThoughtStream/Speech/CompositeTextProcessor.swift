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
        // Detect command mode on the raw segment first. Both a matched command AND a keyword-led
        // unrecognized command (feedback 0005) are returned untouched: a segment that led with the
        // control word is command mode and must NEVER be spelling-mangled or transcribed - it either
        // runs or is dropped with a chip.
        let commandResult = command.process(text)
        switch commandResult {
        case .command, .unrecognizedCommand:
            return commandResult
        case .text, .drop:
            // Not command mode: apply spelling overrides to the dictated text.
            return spelling.process(text)
        }
    }
}
