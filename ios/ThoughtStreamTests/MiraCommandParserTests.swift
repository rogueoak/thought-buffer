import XCTest
@testable import ThoughtStream

/// The Mira control-word parser (feedback 0006 SPLIT model): the control word is detected as a token
/// ANYWHERE in an accumulating segment, not only at the start. The parser splits at the first
/// control word into the dictation BEFORE it (committed) and command mode FROM it to the end. Covers
/// each command, tolerant filler, synonyms, case-insensitivity, the split point, keyword-led
/// gibberish dropping, and non-keyword speech committing as text.
final class MiraCommandParserTests: XCTestCase {
    private let parser = MiraCommandParser(controlWord: "Mira")

    /// Assert the segment splits with the given pre-text and matched command.
    private func assertCommand(
        _ segment: String, preText: String, _ command: MiraCommand,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            parser.parse(segment),
            .split(preText: preText, command: .command(command)),
            file: file, line: line
        )
    }

    // MARK: - Remove last sentence (keyword-led, no pre-text)

    func testRemoveLastSentence() {
        assertCommand("Mira remove the last sentence", preText: "", .removeLastSentence)
        assertCommand("Mira remove last sentence", preText: "", .removeLastSentence)
        assertCommand("mira delete the last sentence", preText: "", .removeLastSentence)
        assertCommand("MIRA DELETE LAST SENTENCE", preText: "", .removeLastSentence)
        // Trailing comma / filler after the control word is tolerated.
        assertCommand("Mira, please remove the last sentence.", preText: "", .removeLastSentence)
    }

    // MARK: - "delete the last line" / "scratch that" reuse removeLastSentence (spec 0016)

    func testDeleteLastLineFiresRemoveLastSentence() {
        assertCommand("Mira delete the last line", preText: "", .removeLastSentence)
        assertCommand("Mira delete last line", preText: "", .removeLastSentence)
        assertCommand("Mira remove last line", preText: "", .removeLastSentence)
        assertCommand("mira, please delete the last line.", preText: "", .removeLastSentence)
    }

    func testScratchThatFiresRemoveLastSentence() {
        assertCommand("Mira scratch that", preText: "", .removeLastSentence)
        assertCommand("mira, scratch that.", preText: "", .removeLastSentence)
        // "scratch" reduces the same way once trailing/inner filler drops "that".
        assertCommand("Mira scratch", preText: "", .removeLastSentence)
    }

    func testRealClauseAfterLineDoesNotMisfire() {
        // A real clause following the noun is not filler, so it does not match a known command and is
        // dropped as an unrecognized command (never mis-fires removeLastSentence, never transcribed).
        XCTAssertEqual(
            parser.parse("Mira delete the last line of the poem"),
            .split(preText: "", command: .unrecognizedCommand)
        )
        // Plain dictation containing "line" or "scratch" with no control word commits as text.
        XCTAssertEqual(parser.parse("Draw a line under the total."), .text)
        XCTAssertEqual(parser.parse("The cat left a scratch on the door."), .text)
    }

    // MARK: - Remove last paragraph

    func testRemoveLastParagraph() {
        assertCommand("Mira remove the last paragraph", preText: "", .removeLastParagraph)
        assertCommand("Mira delete last paragraph", preText: "", .removeLastParagraph)
        assertCommand("mira remove the last paragraph.", preText: "", .removeLastParagraph)
    }

    // MARK: - New thought

    func testNewThought() {
        assertCommand("Mira new thought", preText: "", .newThought)
        assertCommand("Mira start a new thought", preText: "", .newThought)
        assertCommand("mira, new thought", preText: "", .newThought)
    }

    // MARK: - Read that back (including tolerant trailing filler "to me")

    func testReadThatBack() {
        assertCommand("Mira read that back", preText: "", .readThatBack)
        assertCommand("Mira read it back", preText: "", .readThatBack)
        assertCommand("Mira read back", preText: "", .readThatBack)
        assertCommand("mira read that back please", preText: "", .readThatBack)
    }

    func testReadThatBackWithTrailingFiller() {
        assertCommand("Mira read that back to me", preText: "", .readThatBack)
        assertCommand("Mira read it back for me", preText: "", .readThatBack)
        assertCommand("Mira, please read that back to me.", preText: "", .readThatBack)
    }

    // MARK: - SPLIT: command in the MIDDLE/END of an accumulating segment (feedback 0006)

    /// The core device behavior: a spoken command lands at the END of one accumulating segment. The
    /// dictation before the control word is committed; the command fires.
    func testCommandAtEndOfAccumulatingSegment() {
        assertCommand("here is my thought Mira new thought", preText: "here is my thought", .newThought)
        assertCommand(
            "remember the milk Mira read that back to me",
            preText: "remember the milk", .readThatBack
        )
        assertCommand(
            "Call the supplier. Mira remove the last sentence",
            preText: "Call the supplier.", .removeLastSentence
        )
    }

    /// The pre-text keeps the user's exact casing and inner punctuation; only the split boundary is
    /// derived from the control word.
    func testPreTextPreservesCasingAndPunctuation() {
        XCTAssertEqual(
            parser.parse("Buy Eggs, Milk & Bread mira new thought"),
            .split(preText: "Buy Eggs, Milk & Bread", command: .command(.newThought))
        )
    }

    /// Only the FIRST control-word token splits; the pre-text before it is committed. A later control
    /// word lives inside the command tail, so the tail is no longer a clean single command and drops
    /// as unrecognized - the split boundary is the FIRST control word, not the last.
    func testSplitsAtFirstControlWord() {
        XCTAssertEqual(
            parser.parse("thought one Mira new thought Mira remove last sentence"),
            .split(preText: "thought one", command: .unrecognizedCommand)
        )
    }

    // MARK: - Non-keyword-led speech is TEXT (no control word anywhere)

    func testNoControlWordIsText() {
        XCTAssertEqual(parser.parse("remove the last sentence"), .text)
        XCTAssertEqual(parser.parse("The last sentence of the report was strong."), .text)
        XCTAssertEqual(parser.parse("Let's start a new paragraph about the budget."), .text)
    }

    // MARK: - Keyword present but NOT a known command -> split with unrecognized command

    /// Feedback 0006: a control word anywhere puts the REST into command mode. If it is not a known
    /// command, the pre-text is still committed and the command portion is DROPPED (the view model
    /// shows a chip), never transcribed.
    func testKeywordLedGibberishIsUnrecognizedCommand() {
        XCTAssertEqual(parser.parse("Mira"), .split(preText: "", command: .unrecognizedCommand))
        XCTAssertEqual(
            parser.parse("Mira how are you today"),
            .split(preText: "", command: .unrecognizedCommand)
        )
        XCTAssertEqual(
            parser.parse("Mira flibber"),
            .split(preText: "", command: .unrecognizedCommand)
        )
        // Pre-text present, then keyword-led gibberish: keep the pre-text, drop the command tail.
        XCTAssertEqual(
            parser.parse("here is my thought Mira flibber"),
            .split(preText: "here is my thought", command: .unrecognizedCommand)
        )
        XCTAssertEqual(
            parser.parse("Mira read that thought back to the team"),
            .split(preText: "", command: .unrecognizedCommand)
        )
    }

    // MARK: - Injected / custom control word

    func testCustomControlWord() {
        let custom = MiraCommandParser(controlWord: "Echo")
        XCTAssertEqual(custom.parse("Echo new thought"), .split(preText: "", command: .command(.newThought)))
        XCTAssertEqual(
            custom.parse("here is my thought Echo new thought"),
            .split(preText: "here is my thought", command: .command(.newThought))
        )
        // A different control word leads: command mode, but no match -> unrecognized, not text.
        XCTAssertEqual(custom.parse("Echo blah blah"), .split(preText: "", command: .unrecognizedCommand))
        // "Mira" is no longer the control word, so a Mira-led phrase is ordinary text.
        XCTAssertEqual(custom.parse("Mira new thought"), .text)
    }

    // MARK: - Trigger-word aliases (spec 0018)

    func testAliasFiresCommand() {
        // With aliases {mira, mirror}, "mirror new thought" fires newThought and is NOT written to the thought.
        let aliased = MiraCommandParser(triggerWords: ["Mira", "mirror"])
        XCTAssertEqual(aliased.parse("mirror new thought"), .split(preText: "", command: .command(.newThought)))
        // The primary word still fires.
        XCTAssertEqual(aliased.parse("Mira new thought"), .split(preText: "", command: .command(.newThought)))
    }

    func testAliasMatchesAnyTriggerAndSplitsAtFirst() {
        let aliased = MiraCommandParser(triggerWords: ["Mira", "mirra", "meera", "mirror"])
        // Each alias is fully equivalent to the control word.
        XCTAssertEqual(aliased.parse("mirra read that back"), .split(preText: "", command: .command(.readThatBack)))
        XCTAssertEqual(aliased.parse("meera remove the last sentence"),
                       .split(preText: "", command: .command(.removeLastSentence)))
        // Pre-text before an alias is committed; the alias splits like the primary word.
        XCTAssertEqual(aliased.parse("buy milk mirror new thought"),
                       .split(preText: "buy milk", command: .command(.newThought)))
    }

    func testAliasMatchingIsCaseInsensitive() {
        let aliased = MiraCommandParser(triggerWords: ["Mira", "Mirror"])
        XCTAssertEqual(aliased.parse("MIRROR new thought"), .split(preText: "", command: .command(.newThought)))
        XCTAssertEqual(aliased.parse("MiRrOr new thought"), .split(preText: "", command: .command(.newThought)))
    }

    func testRemovedAliasStopsFiring() {
        // A parser built WITHOUT "mirror" treats a "mirror"-led phrase as ordinary text (the removed
        // alias no longer triggers).
        let onlyPrimary = MiraCommandParser(triggerWords: ["Mira"])
        XCTAssertEqual(onlyPrimary.parse("mirror new thought"), .text)
        XCTAssertEqual(onlyPrimary.parse("Mira new thought"), .split(preText: "", command: .command(.newThought)))
    }

    func testAliasMatchingIsTokenBounded() {
        // Token-boundary must hold: a longer word CONTAINING an alias must not match it.
        let aliased = MiraCommandParser(triggerWords: ["Mira", "mirror"])
        // "admiral" contains "mira" as a substring but not as a token, so it is ordinary text.
        XCTAssertEqual(aliased.parse("the admiral spoke"), .text)
        // "mirrored" contains "mirror" as a substring but not as a token.
        XCTAssertEqual(aliased.parse("the mirrored surface"), .text)
    }

    // MARK: - command(in:) convenience

    func testCommandConvenience() {
        XCTAssertEqual(parser.command(in: "Mira new thought"), .newThought)
        XCTAssertEqual(parser.command(in: "here is my thought Mira new thought"), .newThought)
        XCTAssertNil(parser.command(in: "Mira gibberish"))
        XCTAssertNil(parser.command(in: "an ordinary sentence"))
    }
}
