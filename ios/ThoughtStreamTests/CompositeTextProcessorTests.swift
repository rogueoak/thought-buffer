import XCTest
@testable import ThoughtStream

/// `CompositeTextProcessor`: the composition order that spec 0006 requires. A command is detected
/// FIRST on the raw segment and returned untouched (never spelling-mangled); a normal segment gets
/// overrides applied. Also proves the configured control word changes command matching.
final class CompositeTextProcessorTests: XCTestCase {

    // MARK: - Configured control word changes matching

    func testConfiguredControlWordFiresCommand() {
        let processor = CompositeTextProcessor(controlWord: "Nova", overrides: [])
        XCTAssertEqual(processor.process("Nova remove the last sentence"), .command(.removeLastSentence))
    }

    func testOldControlWordDoesNotFireWhenReconfigured() {
        let processor = CompositeTextProcessor(controlWord: "Nova", overrides: [])
        // "Mira ..." is no longer the control word, so it is committed as text, not a command.
        XCTAssertEqual(processor.process("Mira remove the last sentence"), .text("Mira remove the last sentence"))
    }

    func testPlainWordIsNotACommand() {
        let processor = CompositeTextProcessor(controlWord: "Nova", overrides: [])
        XCTAssertEqual(processor.process("just a normal sentence"), .text("just a normal sentence"))
    }

    // MARK: - Composition order

    func testCommandIsDetectedAndNotSpellingMangled() {
        // An override on a word inside the command phrase must NOT alter the command, because the
        // command is detected first and returned before spelling runs.
        let overrides = [
            SpellingOverride(from: "Nova", to: "SHOULD_NOT_APPEAR"),
            SpellingOverride(from: "last", to: "SHOULD_NOT_APPEAR"),
        ]
        let processor = CompositeTextProcessor(controlWord: "Nova", overrides: overrides)
        XCTAssertEqual(processor.process("Nova remove the last sentence"), .command(.removeLastSentence))
    }

    func testNormalSegmentGetsOverridesApplied() {
        let overrides = [SpellingOverride(from: "Shay", to: "Shea")]
        let processor = CompositeTextProcessor(controlWord: "Mira", overrides: overrides)
        XCTAssertEqual(processor.process("Call Shay tomorrow"), .text("Call Shea tomorrow"))
    }

    func testKeywordLedNonCommandIsUnrecognizedCommandNotText() {
        // Feedback 0005: "Mira" LEADS the segment, so it is command mode. It is not a known command,
        // so it is DROPPED as an unrecognized command (NOT transcribed, and never spelling-mangled),
        // superseding the old behavior of committing it as text.
        let overrides = [SpellingOverride(from: "Shay", to: "Shea")]
        let processor = CompositeTextProcessor(controlWord: "Mira", overrides: overrides)
        XCTAssertEqual(processor.process("Mira told Shay a story"), .unrecognizedCommand)
    }

    func testMidSentenceControlWordMentionGetsOverrides() {
        // The control word appears MID-sentence (not leading), so the segment is ordinary text and
        // overrides still apply.
        let overrides = [SpellingOverride(from: "Shay", to: "Shea")]
        let processor = CompositeTextProcessor(controlWord: "Mira", overrides: overrides)
        XCTAssertEqual(
            processor.process("Call Shay and tell Mira the plan"),
            .text("Call Shea and tell Mira the plan")
        )
    }
}
