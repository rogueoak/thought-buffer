import Foundation

/// Composes the Mira command processor, the spelling-override processor, and (optionally) the
/// filler-removal processor, in that order.
///
/// ORDER MATTERS. A finalized segment is SPLIT at the control word FIRST, on the RAW text (feedback
/// 0006: on device a command lands mid/end of one accumulating segment). Only the DICTATION portion
/// - the whole segment when there is no control word, or the `preText` before one - flows through the
/// spelling processor and then the filler processor; the command portion is never spelling-mangled,
/// filler-stripped, or transcribed. This is the seam spec 0003 left open and spec 0006 fills; spec
/// 0016 adds the filler stage AFTER spelling so it only ever touches committed dictation text.
///
/// The filler stage is present only when the `refineTranscript` setting is on (spec 0016); when off,
/// dictation commits verbatim (today's behavior). It runs LAST on the dictation text so:
///
/// - a whole-segment `.text` that filler removal empties resolves to `.drop`, so the view model
///   creates no empty paragraph and does not advance the paragraph grouper (feedback 0012 coupling);
/// - a `.split` whose `preText` filler removal empties still runs its command, committing no
///   pre-text paragraph (an empty `preText` is already the view model's "command only" case).
///
/// Built per dictation session from current settings (see `AppDependencies.makeTextProcessor`), so
/// edits in Settings take effect on the next session, not one already running.
struct CompositeTextProcessor: TextProcessor {
    private let command: MiraTextProcessor
    private let spelling: SpellingOverrideProcessor
    /// The filler-removal stage, or nil when the refine setting is off (text commits verbatim).
    private let filler: FillerRemovalProcessor?

    init(controlWord: String, overrides: [SpellingOverride], removesFillers: Bool = false) {
        self.command = MiraTextProcessor(controlWord: controlWord)
        self.spelling = SpellingOverrideProcessor(overrides: overrides)
        self.filler = removesFillers ? FillerRemovalProcessor() : nil
    }

    func process(_ text: String) -> ProcessedSegment {
        // Split at the control word on the raw segment first, so the command portion is never
        // spelling-mangled, filler-stripped, or transcribed - it either runs or is dropped with a chip.
        switch command.process(text) {
        case .text:
            // No control word: apply spelling overrides, then filler removal, to the whole segment.
            // Filler removal owns the empty-segment -> `.drop` decision, so return its result directly.
            return refine(spellingText(text))
        case .split(let preText, let outcome):
            // Command mode present. Refine ONLY the pre-keyword dictation; the command portion
            // (`outcome`) is passed through untouched. A pre-text emptied by filler removal commits no
            // paragraph but the command still runs, so keep the split and pass the (possibly empty)
            // refined pre-text rather than dropping the whole segment.
            let refinedPre = refinedPreText(spellingText(preText))
            return .split(preText: refinedPre, command: outcome)
        case .drop:
            return .drop
        }
    }

    /// Apply the filler stage (if enabled) to a whole-segment dictation string. When the stage is off
    /// the text commits verbatim as `.text`; when on, it may resolve to `.drop` if the segment empties.
    private func refine(_ text: String) -> ProcessedSegment {
        guard let filler else { return .text(text) }
        return filler.process(text)
    }

    /// The refined pre-text for a split. Applies the filler stage (if enabled) and returns the string
    /// (empty when filler removal emptied it), because a split always keeps its command and an empty
    /// pre-text is already the view model's "command only, commit nothing" case - so a `.drop` from the
    /// filler stage is folded back into an empty pre-text rather than dropping the command with it.
    private func refinedPreText(_ text: String) -> String {
        guard let filler else { return text }
        switch filler.process(text) {
        case .text(let value):
            return value
        case .drop:
            return ""
        case .split:
            // The filler processor never emits `.split`; fall back to the input unchanged.
            return text
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
