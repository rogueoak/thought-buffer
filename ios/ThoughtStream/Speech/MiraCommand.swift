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

// MARK: - Cheat sheet

extension MiraCommand {
    /// The commands shown on the record-screen cheat sheet, in the order presented to the user
    /// (feedback 0008). The single source for the on-screen command list.
    static let cheatSheet: [MiraCommand] = [
        .newNote, .readThatBack, .removeLastSentence, .removeLastParagraph,
    ]

    /// The canonical spoken phrasing shown after the control word (e.g. "new note"). Kept beside the
    /// parser's grammar so the cheat sheet matches what actually fires.
    var spokenPhrase: String {
        switch self {
        case .removeLastSentence: return "remove last sentence"
        case .removeLastParagraph: return "remove last paragraph"
        case .newNote: return "new note"
        case .readThatBack: return "read that back"
        }
    }

    /// A one-line description of what the command does, for the cheat sheet.
    var cheatSheetDetail: String {
        switch self {
        case .removeLastSentence: return "Delete the last sentence you spoke. Also \"delete the last line\" or \"scratch that\"."
        case .removeLastParagraph: return "Delete the whole last paragraph."
        case .newNote: return "Save this note and start a fresh one."
        case .readThatBack: return "Read your last paragraph aloud."
        }
    }
}

/// The parsed outcome of the command-mode portion of a split segment (the text from the control word
/// to the end). ONE shared type used by both `MiraParseResult.split` (the parser's result) and
/// `ProcessedSegment.split` (the processor's result), so the processor forwards the outcome instead
/// of mechanically re-wrapping an identical enum.
enum CommandOutcome: Equatable {
    /// Matched a known command; execute it (and suppress it from the note).
    case command(MiraCommand)
    /// Led with the control word but matched no known command (feedback 0005): NOT transcribed; the
    /// view model drops it and shows a brief "didn't catch that" chip so the user knows it was
    /// treated as a command rather than silently lost.
    case unrecognizedCommand
}
