import Foundation

/// The result of running a speech segment through a `TextProcessor`.
///
/// A processor can commit transformed text, consume the segment as a command (suppressing it from
/// the note), or drop it entirely. This is the seam where Mira control words hook in and where a
/// future spelling-override processor will transform text, both without changing the view model
/// or the capture service.
enum ProcessedSegment: Equatable {
    /// Text to commit as a paragraph (unchanged for a passthrough, transformed otherwise).
    case text(String)
    /// The segment was a control-word command: suppress it from the note and execute it.
    case command(MiraCommand)
    /// The segment LED with the control word but matched no known command (feedback 0005). It is
    /// still command mode - so it is NOT transcribed - but there is nothing to run: the view model
    /// drops it and shows a brief "didn't catch that" chip so the user knows it was treated as a
    /// command rather than silently lost.
    case unrecognizedCommand
    /// Discard the segment entirely with no user feedback. Reserved; not emitted by the shipped
    /// processors.
    case drop
}

/// A thin, injectable transform applied to speech text between recognition and the note.
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
