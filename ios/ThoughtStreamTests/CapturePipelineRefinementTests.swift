import XCTest
@testable import ThoughtStream

/// Pins the "good output" of the refinement layer (capture-pipeline feedback 0026) against
/// REPRESENTATIVE, realistic transcripts - the kind of multi-sentence dictation the iOS 26
/// `SpeechTranscriber` now produces once it is fed clean input (`.spokenAudio` mode) and its native
/// punctuation is preserved. These tests are the regression guard the feedback doc asks for: with
/// refinement ON, filler removal must strike ONLY genuine hesitations, must NOT eat legitimate words,
/// numbers, or sentence punctuation, and the result must read faithfully. If a future tidy/regex or
/// filler-set change starts damaging clean punctuated text, one of these fails.
///
/// Refinement here is the whole per-session pipeline (`CompositeTextProcessor` with `removesFillers:
/// true`), matching what `AppDependencies.makeTextProcessor` builds when `refineTranscript` is on. The
/// pure `ParagraphGrouper` (which is not text-refinement) keeps its own suite.
final class CapturePipelineRefinementTests: XCTestCase {

    /// The refining processor as the app builds it for a session with refinement on: control word
    /// "Mira", no spelling overrides, filler removal enabled.
    private func refiner() -> CompositeTextProcessor {
        CompositeTextProcessor(controlWord: "Mira", overrides: [], removesFillers: true)
    }

    /// Convenience: run a segment through refinement and return the committed text, failing the test
    /// if the segment split into a command or dropped (these fixtures are all plain dictation).
    private func refined(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        switch refiner().process(text) {
        case .text(let value):
            return value
        case .drop:
            XCTFail("expected committed text, got .drop", file: file, line: line)
            return ""
        case .split:
            XCTFail("expected committed text, got .split", file: file, line: line)
            return ""
        }
    }

    // MARK: - Punctuation is preserved, not collapsed

    func testPunctuatedSentencesSurviveVerbatimWhenNoFillers() {
        // A clean, already-punctuated multi-sentence transcript must pass through UNCHANGED. This is the
        // core non-destructiveness guarantee: refinement must never rewrite good text.
        let input = "The meeting is at 3:30. Bring the report, the slides, and your notes."
        XCTAssertEqual(refined(input), "The meeting is at 3:30. Bring the report, the slides, and your notes.")
    }

    func testQuestionAndExclamationMarksSurvive() {
        let input = "Are we still on for tomorrow? Great, I cannot wait!"
        XCTAssertEqual(refined(input), "Are we still on for tomorrow? Great, I cannot wait!")
    }

    func testNumbersAndUnitsAreNotStripped() {
        // "mm" and other unit-like tokens are deliberately excluded from the filler set, so a measurement
        // is never mangled into a factual error ("20 mm" must not become "20").
        let input = "We got 20 mm of rain and it dropped to 5 degrees by 9 p.m."
        XCTAssertEqual(refined(input), "We got 20 mm of rain and it dropped to 5 degrees by 9 p.m.")
    }

    // MARK: - Fillers removed faithfully, punctuation intact

    func testLeadingAndInteriorFillersRemovedThenReadsClean() {
        // Genuine hesitations at the start and mid-sentence are removed; the leading word is
        // re-capitalized and the surrounding commas/spacing tidy up, with nothing else touched.
        let input = "um so, uh, the plan is to ship on Friday"
        XCTAssertEqual(refined(input), "So, the plan is to ship on Friday")
    }

    func testFillersRemovedButRealWordsAndPunctuationKept() {
        // A realistic sentence with a hesitation embedded: the "uh" goes, everything else - including the
        // comma and the terminal period - stays exactly as spoken.
        let input = "I think, uh, we should call the client, then send the invoice."
        XCTAssertEqual(refined(input), "I think, we should call the client, then send the invoice.")
    }

    func testFillerInsideRealWordIsNeverStripped() {
        // Whole-token matching only: "um"/"uh" runs inside real words must survive untouched.
        XCTAssertEqual(refined("I am humbled and hungry"), "I am humbled and hungry")
    }

    func testFillerInsideQuotedSpanIsKeptVerbatim() {
        // A hesitation the user is quoting is literal content, not their own filler: the quoted "um" run
        // survives untouched.
        let input = "The transcript read \"um no thanks\""
        XCTAssertEqual(refined(input), "The transcript read \"um no thanks\"")
    }

    // MARK: - Natural pause paragraphing (grouper is faithful with punctuation present)

    func testGrouperFlowsWithinAThoughtAndBreaksOnAPause() {
        // A representative sequence: two finalized segments close together (a mid-thought breath) FLOW into
        // one paragraph; a segment after a real ~2s pause STARTS a new one. Pins that the default 1.5s
        // threshold still reads like Notes now that segments arrive punctuated.
        var grouper = ParagraphGrouper()
        // First segment of the analysis: always a new paragraph, ends at t=2.0.
        XCTAssertEqual(
            grouper.decide(startSeconds: 0.0, durationSeconds: 2.0, isAnalysisStart: true), .newParagraph)
        // 0.3s breath later: flows into the same paragraph.
        XCTAssertEqual(
            grouper.decide(startSeconds: 2.3, durationSeconds: 1.5, isAnalysisStart: false), .appendToCurrent)
        // A deliberate ~2s pause later: a new paragraph.
        XCTAssertEqual(
            grouper.decide(startSeconds: 5.8, durationSeconds: 1.0, isAnalysisStart: false), .newParagraph)
    }
}
