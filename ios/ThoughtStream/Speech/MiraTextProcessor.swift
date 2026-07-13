import Foundation

/// The `TextProcessor` that recognizes Mira control words.
///
/// Wraps a `MiraCommandParser` (with the injected control word). A finalized segment that parses
/// as a command is returned as `.command` so the view model executes it and keeps the phrase out
/// of the note; anything else is returned as `.text` to commit unchanged.
///
/// A future spelling-override processor composes here: parse for a command first, and if none,
/// run the text transform and return `.text`.
struct MiraTextProcessor: TextProcessor {
    private let parser: MiraCommandParser

    /// The default control word for this milestone. A single constant so a later Settings
    /// milestone can make it configurable in one place.
    static let defaultControlWord = "Mira"

    init(controlWord: String = MiraTextProcessor.defaultControlWord) {
        self.parser = MiraCommandParser(controlWord: controlWord)
    }

    func process(_ text: String) -> ProcessedSegment {
        if let command = parser.parse(text) {
            return .command(command)
        }
        return .text(text)
    }
}
