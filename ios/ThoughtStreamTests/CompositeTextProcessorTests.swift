import XCTest
@testable import ThoughtStream

/// `CompositeTextProcessor`: the composition order that spec 0006 requires, updated for the
/// feedback-0006 SPLIT model. A segment is split at the control word FIRST (on the raw text), so the
/// command portion is never spelling-mangled; spelling overrides apply ONLY to the pre-keyword
/// dictation. Also proves the configured control word changes command matching.
final class CompositeTextProcessorTests: XCTestCase {

    // MARK: - Configured control word changes matching

    func testConfiguredControlWordFiresCommand() {
        let processor = CompositeTextProcessor(controlWord: "Nova", overrides: [])
        XCTAssertEqual(
            processor.process("Nova remove the last sentence"),
            .split(preText: "", command: .command(.removeLastSentence))
        )
    }

    func testOldControlWordDoesNotFireWhenReconfigured() {
        let processor = CompositeTextProcessor(controlWord: "Nova", overrides: [])
        // "Mira ..." is no longer the control word, so it is committed as text, not a command.
        XCTAssertEqual(
            processor.process("Mira remove the last sentence"),
            .text("Mira remove the last sentence")
        )
    }

    func testPlainWordIsNotACommand() {
        let processor = CompositeTextProcessor(controlWord: "Nova", overrides: [])
        XCTAssertEqual(processor.process("just a normal sentence"), .text("just a normal sentence"))
    }

    // MARK: - Split point: command mid/end of accumulating segment (feedback 0006)

    func testCommandAtEndSplitsAndCommitsPreText() {
        let processor = CompositeTextProcessor(controlWord: "Mira", overrides: [])
        XCTAssertEqual(
            processor.process("here is my thought Mira new thought"),
            .split(preText: "here is my thought", command: .command(.newThought))
        )
    }

    // MARK: - Composition order: command is never spelling-mangled

    func testCommandIsDetectedAndNotSpellingMangled() {
        // An override on a word inside the command phrase must NOT alter the command, because the
        // command portion is split off first and never flows through spelling.
        let overrides = [
            SpellingOverride(from: "Nova", to: "SHOULD_NOT_APPEAR"),
            SpellingOverride(from: "last", to: "SHOULD_NOT_APPEAR"),
            SpellingOverride(from: "new", to: "SHOULD_NOT_APPEAR"),
            SpellingOverride(from: "thought", to: "SHOULD_NOT_APPEAR"),
        ]
        let processor = CompositeTextProcessor(controlWord: "Nova", overrides: overrides)
        XCTAssertEqual(
            processor.process("Nova remove the last sentence"),
            .split(preText: "", command: .command(.removeLastSentence))
        )
    }

    func testNormalSegmentGetsOverridesApplied() {
        let overrides = [SpellingOverride(from: "Shay", to: "Shea")]
        let processor = CompositeTextProcessor(controlWord: "Mira", overrides: overrides)
        XCTAssertEqual(processor.process("Call Shay tomorrow"), .text("Call Shea tomorrow"))
    }

    // MARK: - Spelling applies to the PRE-KEYWORD dictation but never the command (feedback 0006 (f))

    func testSpellingAppliesToPreTextButNotCommand() {
        // "Shay" -> "Shea" applies to the dictation before the control word. "new"/"thought" overrides
        // (bogus, to prove the point) must NOT touch the command portion.
        let overrides = [
            SpellingOverride(from: "Shay", to: "Shea"),
            SpellingOverride(from: "new", to: "MANGLED"),
            SpellingOverride(from: "thought", to: "MANGLED"),
        ]
        let processor = CompositeTextProcessor(controlWord: "Mira", overrides: overrides)
        XCTAssertEqual(
            processor.process("Call Shay tomorrow Mira new thought"),
            .split(preText: "Call Shea tomorrow", command: .command(.newThought))
        )
    }

    func testKeywordLedNonCommandIsSplitUnrecognizedNotText() {
        // Feedback 0006: "Mira" is present, so the rest is command mode. It is not a known command,
        // so it is DROPPED as an unrecognized command (NOT transcribed, never spelling-mangled). The
        // pre-text (here empty) would be committed if present.
        let overrides = [SpellingOverride(from: "Shay", to: "Shea")]
        let processor = CompositeTextProcessor(controlWord: "Mira", overrides: overrides)
        XCTAssertEqual(
            processor.process("Mira told Shay a story"),
            .split(preText: "", command: .unrecognizedCommand)
        )
    }

    // MARK: - Filler stage (spec 0016): only when enabled, only on dictation text

    func testFillerRemovedWhenEnabled() {
        let processor = CompositeTextProcessor(controlWord: "Mira", overrides: [], removesFillers: true)
        XCTAssertEqual(processor.process("um so, uh, the plan"), .text("So, the plan"))
    }

    func testFillerNotRemovedWhenDisabled() {
        // Default (removesFillers: false) commits verbatim - today's behavior.
        let processor = CompositeTextProcessor(controlWord: "Mira", overrides: [])
        XCTAssertEqual(processor.process("um so, uh, the plan"), .text("um so, uh, the plan"))
    }

    func testFillerOnlySegmentDropsWhenEnabled() {
        // A segment that is nothing but fillers drops, so the view model creates no empty paragraph.
        let processor = CompositeTextProcessor(controlWord: "Mira", overrides: [], removesFillers: true)
        XCTAssertEqual(processor.process("um uh hmm"), .drop)
    }

    func testFillerRunsAfterSpellingOnPreText() {
        // Spelling applies to the pre-text, then filler removal; the command portion is untouched.
        let overrides = [SpellingOverride(from: "Shay", to: "Shea")]
        let processor = CompositeTextProcessor(controlWord: "Mira", overrides: overrides, removesFillers: true)
        XCTAssertEqual(
            processor.process("um call Shay Mira new thought"),
            .split(preText: "Call Shea", command: .command(.newThought))
        )
    }

    func testFillerNeverTouchesCommandPortion() {
        // The command remainder is split off before the filler stage, so the command still fires with
        // filler removal on.
        let processor = CompositeTextProcessor(controlWord: "Mira", overrides: [], removesFillers: true)
        XCTAssertEqual(
            processor.process("Mira remove the last sentence"),
            .split(preText: "", command: .command(.removeLastSentence))
        )
    }

    func testFillerEmptiedPreTextStillRunsCommand() {
        // A pre-text that is nothing but fillers empties, but the command still runs (empty pre-text is
        // the view model's "command only" case); the whole segment is NOT dropped.
        let processor = CompositeTextProcessor(controlWord: "Mira", overrides: [], removesFillers: true)
        XCTAssertEqual(
            processor.process("um uh Mira new thought"),
            .split(preText: "", command: .command(.newThought))
        )
    }

    func testFillerDoesNotAlterIAmHungryThroughComposite() {
        let processor = CompositeTextProcessor(controlWord: "Mira", overrides: [], removesFillers: true)
        XCTAssertEqual(processor.process("I am hungry"), .text("I am hungry"))
    }
}
