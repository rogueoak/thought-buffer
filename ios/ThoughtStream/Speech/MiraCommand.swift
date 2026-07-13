import Foundation

/// A hands-free voice-editing command recognized from a finalized speech segment.
///
/// A control word ("Mira") followed by a command is executed as an action instead of being
/// written into the note. See `MiraCommandParser` for the grammar and `DictationViewModel` for
/// execution.
enum MiraCommand: Equatable {
    /// Delete the last sentence of the current note.
    case removeLastSentence
    /// Delete the last paragraph of the current note.
    case removeLastParagraph
    /// Save the current note and start a fresh one, keeping the session running.
    case newNote
    /// Speak the last paragraph aloud (text to speech).
    case readThatBack
}
