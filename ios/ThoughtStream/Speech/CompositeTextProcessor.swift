import Foundation

/// Composes the Mira command processor with the spelling-override processor, in that order.
///
/// ORDER MATTERS. A finalized segment is SPLIT at the control word FIRST, on the RAW text (feedback
/// 0006: on device a command lands mid/end of one accumulating segment). Only the DICTATION portion
/// - the whole segment when there is no control word, or the `preText` before one - flows through the
/// spelling processor; the command portion is never spelling-mangled or transcribed. This is the
/// seam spec 0003 left open and spec 0006 fills.
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
        // Split at the control word on the raw segment first, so the command portion is never
        // spelling-mangled or transcribed - it either runs or is dropped with a chip.
        switch command.process(text) {
        case .text:
            // No control word: apply spelling overrides to the whole dictated segment.
            return spelling.process(text)
        case .split(let preText, let outcome):
            // Command mode present. Apply spelling overrides ONLY to the pre-keyword dictation; the
            // command portion (`outcome`) is passed through untouched.
            let processedPre = spellingText(preText)
            return .split(preText: processedPre, command: outcome)
        case .drop:
            return .drop
        }
    }

    /// Run `text` through the spelling processor and return the transformed string. The spelling
    /// processor always yields `.text`, so this unwraps it; any other case (which it never emits)
    /// falls back to the input unchanged.
    private func spellingText(_ text: String) -> String {
        if case .text(let value) = spelling.process(text) { return value }
        return text
    }
}
