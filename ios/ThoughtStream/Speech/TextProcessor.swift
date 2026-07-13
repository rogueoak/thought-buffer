import Foundation

/// A thin, injectable transform applied to speech text between recognition and the note.
///
/// Every finalized segment (and the live partial) passes through `process` before it reaches the
/// view model's paragraphs. The default is a pass-through no-op. This is the seam where later
/// milestones plug in Mira control words and spelling overrides without changing the view model
/// or the capture service.
protocol TextProcessor {
    /// Transform a piece of recognized speech into the text that should be shown or committed.
    func process(_ text: String) -> String
}

/// The default processor: returns the text unchanged.
struct PassthroughTextProcessor: TextProcessor {
    func process(_ text: String) -> String { text }
}
