import XCTest
@testable import ThoughtStream

/// Tests for the pure file-transcription mapping (spec 0023): decoded segments -> paragraphs + timings.
/// This is the phone-side ingest core, factored so it is provable WITHOUT a live mic, a real watch, or a
/// running transcriber - the acceptance criterion the spec calls out. It reuses the same
/// `ParagraphGrouper` and `ParagraphTiming.merged` seams the live dictation path uses, so these assert
/// the file path groups paragraphs identically (by silence gap) and merges ranges correctly.
final class FileTranscriptionMapperTests: XCTestCase {
    func testEmptySegmentsMapToEmpty() {
        XCTAssertEqual(FileTranscriptionMapper.map(segments: []), .empty)
    }

    func testSingleSegmentIsOneParagraphWithItsRange() {
        let segments = [TranscribedSegment(text: "Hello world", startSeconds: 0, durationSeconds: 2)]
        let mapping = FileTranscriptionMapper.map(segments: segments)
        XCTAssertEqual(mapping.paragraphs, ["Hello world"])
        XCTAssertEqual(mapping.timings, [ParagraphTiming(start: 0, duration: 2)])
    }

    func testShortGapFlowsIntoOneParagraph() {
        // Two segments 0.5s apart (below the 1.5s gap threshold) flow into one paragraph with a merged
        // range spanning first-start through last-end.
        let segments = [
            TranscribedSegment(text: "First part", startSeconds: 0, durationSeconds: 2),
            TranscribedSegment(text: "second part", startSeconds: 2.5, durationSeconds: 1.5),
        ]
        let mapping = FileTranscriptionMapper.map(segments: segments)
        XCTAssertEqual(mapping.paragraphs, ["First part second part"])
        XCTAssertEqual(mapping.timings.count, 1)
        XCTAssertEqual(mapping.timings[0].start, 0, accuracy: 0.001)
        // end = 2.5 + 1.5 = 4.0, so duration spans 0 -> 4.0
        XCTAssertEqual(mapping.timings[0].duration, 4.0, accuracy: 0.001)
    }

    func testLongGapBreaksIntoTwoParagraphs() {
        // A 3s gap (>= the 1.5s threshold) is a real pause: two paragraphs, each with its own range.
        let segments = [
            TranscribedSegment(text: "First thought", startSeconds: 0, durationSeconds: 2),
            TranscribedSegment(text: "Second thought", startSeconds: 5, durationSeconds: 2),
        ]
        let mapping = FileTranscriptionMapper.map(segments: segments)
        XCTAssertEqual(mapping.paragraphs, ["First thought", "Second thought"])
        XCTAssertEqual(mapping.timings, [
            ParagraphTiming(start: 0, duration: 2),
            ParagraphTiming(start: 5, duration: 2),
        ])
    }

    func testWhitespaceSegmentsAreSkipped() {
        let segments = [
            TranscribedSegment(text: "Real text", startSeconds: 0, durationSeconds: 2),
            TranscribedSegment(text: "   ", startSeconds: 2.1, durationSeconds: 0.5),
        ]
        let mapping = FileTranscriptionMapper.map(segments: segments)
        XCTAssertEqual(mapping.paragraphs, ["Real text"])
        XCTAssertEqual(mapping.timings.count, 1)
    }

    func testDegenerateRangeStillKeepsTextWithPlaceholderTiming() {
        // A segment with a zero/negative duration carries no real range; the text is kept with a
        // zero-length placeholder so the paragraph/timing arrays stay aligned.
        let segments = [TranscribedSegment(text: "No timing", startSeconds: 0, durationSeconds: 0)]
        let mapping = FileTranscriptionMapper.map(segments: segments)
        XCTAssertEqual(mapping.paragraphs, ["No timing"])
        XCTAssertEqual(mapping.timings, [ParagraphTiming(start: 0, duration: 0)])
    }

    func testTimingsAlignOneToOneWithParagraphs() {
        // Mixed gaps: seg1+seg2 flow (0.5s gap), seg3 breaks (3s gap). Two paragraphs, two timings.
        let segments = [
            TranscribedSegment(text: "a", startSeconds: 0, durationSeconds: 1),
            TranscribedSegment(text: "b", startSeconds: 1.5, durationSeconds: 1),
            TranscribedSegment(text: "c", startSeconds: 6, durationSeconds: 1),
        ]
        let mapping = FileTranscriptionMapper.map(segments: segments)
        XCTAssertEqual(mapping.paragraphs.count, mapping.timings.count)
        XCTAssertEqual(mapping.paragraphs, ["a b", "c"])
    }
}
