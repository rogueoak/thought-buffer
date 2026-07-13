import Foundation

/// The `TextProcessor` that recognizes Mira control words.
///
/// Wraps a `MiraCommandParser` (with the injected control word). A finalized segment is SPLIT at the
/// first control word (feedback 0006): the dictation before it becomes `.split` `preText` and the
/// text from the control word to the end becomes the command outcome. A segment with no control word
/// is returned as `.text` to commit unchanged.
///
/// The spelling-override processor composes here (see `CompositeTextProcessor`): it applies overrides
/// to the `preText` only, never to the command portion.
struct MiraTextProcessor: TextProcessor {
    private let parser: MiraCommandParser

    /// The default control word. Owned by the Settings `ControlPhrase` seam (which also owns
    /// validation and its fallback); re-exported here so callers with only the speech layer in
    /// scope keep a stable reference. The layering points one way: this defers to `ControlPhrase`,
    /// not the reverse.
    static let defaultControlWord = ControlPhrase.defaultWord

    init(controlWord: String = MiraTextProcessor.defaultControlWord) {
        self.parser = MiraCommandParser(controlWord: controlWord)
    }

    func process(_ text: String) -> ProcessedSegment {
        switch parser.parse(text) {
        case .text:
            return .text(text)
        case .split(let preText, let command):
            // `preText` is returned raw here; `CompositeTextProcessor` applies spelling overrides to
            // it. The command portion is never transcribed, so it carries no text.
            switch command {
            case .command(let matched):
                return .split(preText: preText, command: .command(matched))
            case .unrecognizedCommand:
                return .split(preText: preText, command: .unrecognizedCommand)
            }
        }
    }
}
