import Foundation

/// The result of running a speech segment through a `TextProcessor`.
///
/// A processor can commit transformed text, or SPLIT an accumulating segment at the control word
/// into a leading dictation paragraph plus a command outcome (feedback 0006). This is the seam where
/// Mira control words hook in and where the spelling-override processor transforms text, both
/// without changing the view model or the capture service.
enum ProcessedSegment: Equatable {
    /// Text to commit as a paragraph (unchanged for a passthrough, transformed otherwise). No
    /// control word was found in the segment.
    case text(String)
    /// The segment contained the control word (feedback 0006: on device a command lands mid/end of
    /// one accumulating segment, not at its start). `preText` is the dictation BEFORE the control
    /// word - committed as a paragraph if non-empty (with spelling overrides applied) - and `command`
    /// is the command-mode outcome from the control word to the end (never transcribed). `command`
    /// is the shared `CommandOutcome`, so the processor forwards the parser's outcome unchanged.
    case split(preText: String, command: CommandOutcome)
    /// Discard the segment entirely with no user feedback. Reserved; not emitted by the shipped
    /// processors.
    case drop
}

/// A thin, injectable transform applied to speech text between recognition and the thought.
///
/// Every finalized segment passes through `process` before it reaches the view model's
/// paragraphs. The default is a pass-through that always returns `.text`. This is the seam where
/// Mira control words consume commands and where later milestones plug in spelling overrides,
/// without changing the view model or the capture service.
protocol TextProcessor {
    /// Classify or transform a finalized piece of recognized speech.
    func process(_ text: String) -> ProcessedSegment
}

/// The default processor: returns the text unchanged, never a command.
struct PassthroughTextProcessor: TextProcessor {
    func process(_ text: String) -> ProcessedSegment { .text(text) }
}
