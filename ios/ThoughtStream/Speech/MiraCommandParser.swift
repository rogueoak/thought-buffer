import Foundation

/// Turns a finalized speech segment into a `MiraCommand`, or nil when the segment is ordinary
/// speech that should be committed to the note.
///
/// Pure and unit-testable: no side effects, no dependencies beyond the injected control word.
/// The grammar (see `docs/specs/0003-mira-control-words.md`):
///
/// - The control word must lead the segment ("mira ..."). This keeps a passing mention of the
///   word mid-sentence from misfiring.
/// - Matching is case-insensitive and phrase-based: the remainder's tokens must contain the key
///   tokens of a command in order, so filler ("the", "that") is tolerated.
/// - "delete" is a synonym of "remove".
///
/// Grammar (remainder after the control word):
/// - removeLastSentence:  (remove | delete) [the] last sentence
/// - removeLastParagraph: (remove | delete) [the] last paragraph
/// - newNote:             new note | start [a] new note
/// - readThatBack:        read [that | it] back | read back [that | it]
struct MiraCommandParser {
    /// The control word that must lead a command. Injected so a later Settings milestone can make
    /// it configurable; fixed to "Mira" for now.
    let controlWord: String

    init(controlWord: String) {
        self.controlWord = controlWord
    }

    /// Parse a finalized segment. Returns the recognized command, or nil to commit the text.
    func parse(_ segment: String) -> MiraCommand? {
        let tokens = Self.tokenize(segment)
        guard let first = tokens.first else { return nil }

        // Require the control word at the very start of the segment.
        guard first == controlWord.lowercased() else { return nil }

        let rest = Array(tokens.dropFirst())
        guard !rest.isEmpty else { return nil }

        if matchesRemoveLast(rest, unit: "sentence") { return .removeLastSentence }
        if matchesRemoveLast(rest, unit: "paragraph") { return .removeLastParagraph }
        if matchesNewNote(rest) { return .newNote }
        if matchesReadBack(rest) { return .readThatBack }

        return nil
    }

    // MARK: - Command matchers

    /// (remove | delete) ... last ... <unit>, tolerating filler between the key tokens.
    private func matchesRemoveLast(_ tokens: [String], unit: String) -> Bool {
        guard let verbIndex = tokens.firstIndex(where: { $0 == "remove" || $0 == "delete" })
        else { return false }
        let after = Array(tokens[(verbIndex + 1)...])
        return containsInOrder(after, ["last", unit])
    }

    /// new note | start [a] new note.
    private func matchesNewNote(_ tokens: [String]) -> Bool {
        containsInOrder(tokens, ["new", "note"])
    }

    /// read [that | it] back | read back [that | it]. Requires both "read" and "back".
    private func matchesReadBack(_ tokens: [String]) -> Bool {
        containsInOrder(tokens, ["read", "back"]) || containsInOrder(tokens, ["read", "that", "back"])
    }

    // MARK: - Helpers

    /// True when `needles` appear in `tokens` in order (not necessarily adjacent).
    private func containsInOrder(_ tokens: [String], _ needles: [String]) -> Bool {
        var i = 0
        for token in tokens {
            if token == needles[i] {
                i += 1
                if i == needles.count { return true }
            }
        }
        return false
    }

    /// Lowercase, strip punctuation, and split into whitespace-separated word tokens.
    static func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
