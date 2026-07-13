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
            processor.process("here is my note Mira new note"),
            .split(preText: "here is my note", command: .command(.newNote))
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
            SpellingOverride(from: "note", to: "SHOULD_NOT_APPEAR"),
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
        // "Shay" -> "Shea" applies to the dictation before the control word. "new"/"note" overrides
        // (bogus, to prove the point) must NOT touch the command portion.
        let overrides = [
            SpellingOverride(from: "Shay", to: "Shea"),
            SpellingOverride(from: "new", to: "MANGLED"),
            SpellingOverride(from: "note", to: "MANGLED"),
        ]
        let processor = CompositeTextProcessor(controlWord: "Mira", overrides: overrides)
        XCTAssertEqual(
            processor.process("Call Shay tomorrow Mira new note"),
            .split(preText: "Call Shea tomorrow", command: .command(.newNote))
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
}
