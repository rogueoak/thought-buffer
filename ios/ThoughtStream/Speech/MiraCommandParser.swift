import Foundation

/// Turns a finalized speech segment into a `MiraCommand`, or nil when the segment is ordinary
/// speech that should be committed to the note.
///
/// Pure and unit-testable: no side effects, no dependencies beyond the injected control word.
/// The grammar (see `docs/specs/0003-mira-control-words.md`):
///
/// - The control word must lead the segment ("mira ..."). This keeps a passing mention of the
///   word mid-sentence from misfiring.
/// - Matching is case-insensitive and exact against the command phrases: the tokens after the
///   control word (minus documented filler) must BE a command phrase, not merely contain its key
///   tokens. This stops "Mira, there's a new note from Karen" from firing newNote and
///   "Mira read that note back to the team" from firing readThatBack.
/// - Documented filler ("the", "that", "it", "a", "please") is tolerated where the grammar allows,
///   and leading/trailing punctuation is stripped by tokenization.
/// - "delete" is a synonym of "remove".
///
/// Grammar (remainder after the control word, all case-insensitive; bracketed tokens optional):
/// - removeLastSentence:  [please] (remove | delete) [the] last sentence [please]
/// - removeLastParagraph: [please] (remove | delete) [the] last paragraph [please]
/// - newNote:             [please] (new note | start [a] new note) [please]
/// - readThatBack:        [please] (read [that | it] back | read back [that | it]) [please]
struct MiraCommandParser {
    /// The control word that must lead a command. Injected so a later Settings milestone can make
    /// it configurable; fixed to "Mira" for now.
    let controlWord: String

    init(controlWord: String) {
        self.controlWord = controlWord
    }

    /// Filler words tolerated at the very start (after the control word) and the very end of a
    /// command phrase. These are politeness words that carry no meaning for the grammar.
    private static let outerFiller: Set<String> = ["please"]

    /// Parse a finalized segment. Returns the recognized command, or nil to commit the text.
    func parse(_ segment: String) -> MiraCommand? {
        let tokens = Self.tokenize(segment)
        guard let first = tokens.first else { return nil }

        // Require the control word at the very start of the segment.
        guard first == controlWord.lowercased() else { return nil }

        // Strip the control word, then any leading/trailing politeness filler, so what remains is
        // exactly the command phrase (or nothing / something that is not a command).
        var rest = Array(tokens.dropFirst())
        while let f = rest.first, Self.outerFiller.contains(f) { rest.removeFirst() }
        while let l = rest.last, Self.outerFiller.contains(l) { rest.removeLast() }
        guard !rest.isEmpty else { return nil }

        for (patterns, command) in Self.grammar {
            if patterns.contains(where: { matches(rest, pattern: $0) }) {
                return command
            }
        }
        return nil
    }

    // MARK: - Grammar

    /// A phrase pattern: a fixed sequence of `Token`s that the remainder must match exactly.
    private enum Token: Equatable {
        /// A required literal token, or one of a set of alternatives (e.g. remove | delete).
        case oneOf([String])
        /// An optional filler token, or one of a set of alternatives (e.g. [the], [that | it]).
        case optional([String])
    }

    /// Each command's accepted phrasings, tried in order. The remainder must match one pattern
    /// EXACTLY (every remainder token consumed, no arbitrary extra words), which is what stops the
    /// loose-subsequence false positives.
    private static let grammar: [([[Token]], MiraCommand)] = [
        ([[.oneOf(["remove", "delete"]), .optional(["the"]), .oneOf(["last"]), .oneOf(["sentence"])]],
         .removeLastSentence),
        ([[.oneOf(["remove", "delete"]), .optional(["the"]), .oneOf(["last"]), .oneOf(["paragraph"])]],
         .removeLastParagraph),
        ([[.oneOf(["new"]), .oneOf(["note"])],
          [.oneOf(["start"]), .optional(["a"]), .oneOf(["new"]), .oneOf(["note"])]],
         .newNote),
        ([[.oneOf(["read"]), .optional(["that", "it"]), .oneOf(["back"])],
          [.oneOf(["read"]), .oneOf(["back"]), .optional(["that", "it"])]],
         .readThatBack),
    ]

    /// True when `tokens` match `pattern` exactly: each required token consumed in order, optional
    /// tokens consumed when present, and no leftover tokens at the end.
    private func matches(_ tokens: [String], pattern: [Token]) -> Bool {
        var i = 0
        for token in pattern {
            switch token {
            case .oneOf(let alts):
                guard i < tokens.count, alts.contains(tokens[i]) else { return false }
                i += 1
            case .optional(let alts):
                if i < tokens.count, alts.contains(tokens[i]) { i += 1 }
            }
        }
        // Exact match: every remainder token must have been consumed.
        return i == tokens.count
    }

    // MARK: - Helpers

    /// Lowercase, strip punctuation, and split into whitespace-separated word tokens.
    static func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
