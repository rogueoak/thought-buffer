import Foundation

/// The outcome of running a finalized speech segment through the control-word parser.
///
/// The model changed after DEVICE feedback (feedback 0006): on a real device a single recognition
/// task ACCUMULATES the whole spoken passage into one growing transcription, so a spoken command
/// ("Mira new note") lands in the MIDDLE or END of an accumulating segment, not at its start. The
/// old "starts-with-keyword" model therefore never fired for real continuous speech. The parser now
/// SPLITS at the FIRST control-word token:
///
/// - No control word anywhere -> `.text`: commit the whole segment as a paragraph, unchanged.
/// - A control word is present -> `.split`: the text BEFORE it is a normal dictation paragraph
///   (may be empty when the segment leads with the control word), and the text FROM the control word
///   to the end is COMMAND MODE - parsed tolerantly. It either matches a known command (`.command`)
///   or is an unrecognized command that is dropped with a "didn't catch that" chip
///   (`.unrecognizedCommand`).
///
/// The command portion is never transcribed; only `preText` (if non-empty) is committed to the note.
enum MiraParseResult: Equatable {
    /// No control word anywhere in the segment; commit it to the note unchanged.
    case text
    /// A control word was found. `preText` is the dictation before it (empty if it led the segment);
    /// `command` is the parsed outcome of the command mode that follows (the shared `CommandOutcome`).
    case split(preText: String, command: CommandOutcome)
}

/// Turns a finalized speech segment into a `MiraParseResult` by SPLITTING at the first control word.
///
/// Pure and unit-testable: no side effects, no dependencies beyond the injected control word.
/// The grammar (see `docs/specs/0003-mira-control-words.md`, feedback 0005, and feedback 0006):
///
/// - Find the FIRST control-word token anywhere in the segment (case-insensitive, tokenizing on
///   non-alphanumerics). If there is none, the whole segment is `.text`.
/// - If found, everything BEFORE it is the dictation `preText` (committed as a paragraph if
///   non-empty). Everything FROM the control word to the end is COMMAND MODE, never transcribed.
/// - The command remainder (after the control word) is parsed TOLERANTLY: leading/trailing filler
///   ("please", "to me", "for me", "the", "that", "it") is stripped, then what is left must contain a
///   known command phrase. Match -> `.command`; no match -> `.unrecognizedCommand` (dropped, chipped).
/// - "delete" is a synonym of "remove".
///
/// TRADEOFF (feedback 0006): because the control word switches the REST of the utterance to command
/// mode, dictation that literally contains the assistant's name mid-sentence is treated as a command
/// from that point on. The user accepts this and can pick an uncommon control word.
struct MiraCommandParser {
    /// The control word that triggers command mode. Injected so Settings can make it configurable.
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

    /// Parse a finalized segment. Splits at the FIRST control-word token: no control word -> `.text`;
    /// otherwise `.split(preText:command:)` with the dictation before it and the command after it.
    func parse(_ segment: String) -> MiraParseResult {
        guard let split = Self.splitAtControlWord(segment, controlWord: controlWord) else {
            return .text
        }

        // Command mode: parse what follows the control word tolerantly.
        var rest = Self.stripLeadingFiller(split.commandTokens)
        rest = Self.stripTrailingFiller(rest)

        let outcome: CommandOutcome
        if let command = Self.matchCommand(rest) {
            outcome = .command(command)
        } else {
            // Led with the control word but not a known command: drop it (do not transcribe).
            outcome = .unrecognizedCommand
        }
        return .split(preText: split.preText, command: outcome)
    }

    /// Back-compat convenience for callers/tests that only care about the matched command. Returns
    /// the command when one matched, else nil (both "plain text" and "unrecognized command" map to
    /// nil here; callers needing the distinction use `parse`).
    func command(in segment: String) -> MiraCommand? {
        if case .split(_, .command(let command)) = parse(segment) { return command }
        return nil
    }

    // MARK: - Splitting

    /// The result of finding the first control word in a segment: the raw dictation text before it,
    /// and the tokenized command remainder after it.
    private struct Split {
        let preText: String
        let commandTokens: [String]
    }

    /// Find the FIRST control-word token in `segment` (case-insensitive). Returns the raw text before
    /// that token as `preText` (trimmed of trailing whitespace/punctuation) and the tokenized words
    /// AFTER it as `commandTokens`, or nil when the control word never appears.
    ///
    /// Scans the ORIGINAL string so `preText` preserves the user's exact words, casing, and inner
    /// punctuation; only the split boundary is derived from a lowercased token comparison.
    private static func splitAtControlWord(_ segment: String, controlWord: String) -> Split? {
        let key = controlWord.lowercased()
        let ns = segment as NSString
        let matches = wordRegex.matches(in: segment, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            let word = ns.substring(with: match.range)
            guard word.lowercased() == key else { continue }
            // Found the first control-word token. Pre-text is everything before this token; the
            // command tokens are the words after it.
            // Trim only the trailing whitespace/newlines the recognizer left between the dictation
            // and the control word; any punctuation the user spoke just before the control word
            // ("...before noon. Mira new note") is INTENTIONALLY kept on `preText` - it belongs to the
            // sentence being committed, not to the command that follows.
            let preRaw = ns.substring(to: match.range.location)
            let preText = preRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            let afterRange = NSRange(location: match.range.location + match.range.length,
                                     length: ns.length - (match.range.location + match.range.length))
            let after = ns.substring(with: afterRange)
            return Split(preText: preText, commandTokens: tokenize(after))
        }
        return nil
    }

    /// Matches a run of alphanumeric word characters. Splitting on this is equivalent to `tokenize`
    /// so the boundary the split finds lines up with the tokens the grammar matches.
    private static let wordRegex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+")

    // MARK: - Grammar

    /// The known command phrases, tried in order. Each is a list of required token runs; the
    /// remainder must match one of a command's phrasings after filler has been stripped. Matching is
    /// tolerant: the phrase must be PRESENT as the whole remainder (filler already removed), so
    /// "read that back" and "read back" both fire readThatBack, but a trailing real clause ("read
    /// that note back to the team") does not - "note" is not filler, so it does not match and the
    /// segment is dropped as an unrecognized command rather than mis-firing.
    private static let grammar: [([[String]], MiraCommand)] = [
        // "delete/remove last sentence", "delete/remove/scratch last line", and "scratch that" all
        // reuse the existing `removeLastSentence` action (spec 0016): a spoken "line" maps to the last
        // thing said (one sentence), and "scratch that" is the natural no-control-word-noun phrasing.
        // "last paragraph" stays the way to drop a whole block. "scratch that" reduces to "scratch"
        // once inner/trailing filler drops "that", so "scratch" is what the grammar lists.
        (
            [
                ["remove", "last", "sentence"], ["delete", "last", "sentence"],
                ["remove", "last", "line"], ["delete", "last", "line"],
                ["scratch", "that"], ["scratch"],
            ],
            .removeLastSentence
        ),
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
