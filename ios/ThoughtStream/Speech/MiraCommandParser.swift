import Foundation

/// The outcome of running a finalized speech segment through the control-word parser.
///
/// The model changed after on-device feedback (feedback 0005): the user wants "anything that
/// starts with my keyword" to STOP transcribing. So a segment that leads with the control word is
/// always COMMAND MODE - it is never written into the note. It either matches a known command
/// (`.command`) or is dropped as an unrecognized command (`.unrecognizedCommand`, which the view
/// model shows as a brief "didn't catch that" chip). Only a segment that does NOT lead with the
/// control word is ordinary `.text` to commit. This supersedes the earlier strict-match design
/// (which committed a keyword-led non-command as text): keyword-led-unrecognized now DROPS rather
/// than mis-firing, so there is still no wrong-command data loss.
enum MiraParseResult: Equatable {
    /// The segment led with the control word and matched a known command; execute it.
    case command(MiraCommand)
    /// The segment led with the control word but matched no known command; drop it (do NOT
    /// transcribe) and show the user a brief "didn't catch that" chip.
    case unrecognizedCommand
    /// The segment did not lead with the control word; commit it to the note unchanged.
    case text
}

/// Turns a finalized speech segment into a `MiraParseResult`.
///
/// Pure and unit-testable: no side effects, no dependencies beyond the injected control word.
/// The grammar (see `docs/specs/0003-mira-control-words.md` and feedback 0005):
///
/// - The control word must LEAD the segment (after trimming leading punctuation/whitespace,
///   case-insensitive). A leading control word puts the whole segment in COMMAND MODE - it is never
///   transcribed - so a passing mid-sentence mention of the word is still committed as text.
/// - The remainder after the control word is parsed TOLERANTLY: leading/trailing filler ("please",
///   "to me", "for me", "the", "that", "it") is stripped, then what is left must contain a known
///   command phrase. If it does, that command fires; if it does not, the segment is dropped as an
///   unrecognized command (the user gets a chip) rather than transcribed.
/// - "delete" is a synonym of "remove".
struct MiraCommandParser {
    /// The control word that must lead a command. Injected so a later Settings milestone can make
    /// it configurable; fixed to "Mira" for now.
    let controlWord: String

    init(controlWord: String) {
        self.controlWord = controlWord
    }

    /// Filler words/phrases tolerated at the very start and the very end of the command remainder.
    /// These are politeness / connective words that carry no meaning for the grammar. Multi-word
    /// filler ("to me", "for me") is matched as a token run.
    ///
    /// The asymmetry between the two lists is INTENTIONAL, not an oversight - do not "fix" it by
    /// making them match. Only "please" is a natural leading filler after the control word ("Mira
    /// please remove..."); "to"/"the"/"that"/"it" leading the remainder would be part of the command
    /// itself ("Mira the last paragraph" is not a command), so stripping them there would swallow
    /// meaning. Trailing, by contrast, is where politeness and connective tails pile up ("...back to
    /// me please"), so the trailing list is deliberately fuller.
    private static let leadingFiller: Set<String> = ["please"]
    private static let trailingFiller: [[String]] = [
        ["please"], ["to", "me"], ["for", "me"], ["the"], ["that"], ["it"],
    ]

    /// `trailingFiller` pre-sorted longest-run-first, so `stripTrailingFiller` matches multi-word
    /// runs ("to me") before single words ("me") without re-sorting on every loop iteration.
    private static let trailingFillerByLength: [[String]] =
        trailingFiller.sorted { $0.count > $1.count }

    /// Parse a finalized segment. Leads with the control word -> command mode (`.command` or
    /// `.unrecognizedCommand`); otherwise `.text`.
    func parse(_ segment: String) -> MiraParseResult {
        let tokens = Self.tokenize(segment)
        guard let first = tokens.first, first == controlWord.lowercased() else {
            return .text
        }

        // Command mode: the segment leads with the control word. Strip the control word and any
        // outer filler, then look for a known command phrase in what remains.
        var rest = Array(tokens.dropFirst())
        rest = Self.stripLeadingFiller(rest)
        rest = Self.stripTrailingFiller(rest)

        if let command = Self.matchCommand(rest) {
            return .command(command)
        }
        // Led with the control word but is not a known command: drop it (do not transcribe).
        return .unrecognizedCommand
    }

    /// Back-compat convenience for callers/tests that only care about the matched command. Returns
    /// the command when one matched, else nil (both "plain text" and "unrecognized command" map to
    /// nil here; callers needing the distinction use `parse`).
    func command(in segment: String) -> MiraCommand? {
        if case .command(let command) = parse(segment) { return command }
        return nil
    }

    // MARK: - Grammar

    /// The known command phrases, tried in order. Each is a list of required token runs; the
    /// remainder must match one of a command's phrasings after filler has been stripped. Matching is
    /// tolerant: the phrase must be PRESENT as the whole remainder (filler already removed), so
    /// "read that back" and "read back" both fire readThatBack, but a trailing real clause ("read
    /// that note back to the team") does not - "note" is not filler, so it does not match and the
    /// segment is dropped as an unrecognized command rather than mis-firing.
    private static let grammar: [([[String]], MiraCommand)] = [
        ([["remove", "last", "sentence"], ["delete", "last", "sentence"]], .removeLastSentence),
        ([["remove", "last", "paragraph"], ["delete", "last", "paragraph"]], .removeLastParagraph),
        ([["new", "note"], ["start", "new", "note"]], .newNote),
        // "read back that" / "read back it" are omitted: `innerFiller` drops "that"/"it", so they
        // reduce to "read back" (already listed). The distinct phrasings kept here are the ones that
        // differ once inner filler is removed.
        ([["read", "back"], ["read", "that", "back"], ["read", "it", "back"]], .readThatBack),
    ]

    /// Match the filler-stripped remainder against the grammar. A phrase matches when the remainder
    /// equals it after ALSO dropping the inner optional filler ("the", "that", "it", "a") that may
    /// sit between required tokens (e.g. "remove THE last sentence", "start A new note").
    private static func matchCommand(_ rest: [String]) -> MiraCommand? {
        let core = rest.filter { !innerFiller.contains($0) }
        for (phrases, command) in grammar {
            for phrase in phrases {
                let phraseCore = phrase.filter { !innerFiller.contains($0) }
                if core == phraseCore { return command }
            }
        }
        return nil
    }

    /// Optional filler that may appear BETWEEN required command tokens and is ignored when matching
    /// (e.g. "remove the last sentence", "start a new note", "read that back").
    private static let innerFiller: Set<String> = ["the", "a", "that", "it"]

    // MARK: - Filler stripping

    private static func stripLeadingFiller(_ tokens: [String]) -> [String] {
        var rest = tokens
        while let f = rest.first, leadingFiller.contains(f) { rest.removeFirst() }
        return rest
    }

    /// Strip trailing filler runs ("please", "to me", "for me", "the", "that", "it"), longest match
    /// first, repeatedly, so "read that back to me please" reduces to "read that back".
    private static func stripTrailingFiller(_ tokens: [String]) -> [String] {
        var rest = tokens
        var changed = true
        while changed {
            changed = false
            // Try longer filler runs first so "to me" is consumed as a unit before "me" alone.
            // Uses the pre-sorted constant so the list is not re-sorted every iteration.
            for run in trailingFillerByLength {
                if rest.count >= run.count && Array(rest.suffix(run.count)) == run {
                    rest.removeLast(run.count)
                    changed = true
                    break
                }
            }
        }
        return rest
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
