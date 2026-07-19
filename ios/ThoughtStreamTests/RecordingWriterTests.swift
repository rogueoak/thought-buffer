import XCTest
import AVFoundation
@testable import ThoughtStream

/// The tee'd audio writer (spec 0007): injecting PCM buffers writes a file and tracks elapsed audio
/// time. Uses synthesized buffers so it does not depend on a real mic.
final class RecordingWriterTests: XCTestCase {

    private let sampleRate = 44_100.0

    func testAppendWritesFileAndTracksElapsed() throws {
        let writer = RecordingWriter()
        defer { writer.discard() }

        XCTAssertFalse(writer.hasContent)
        XCTAssertEqual(writer.elapsedSeconds, 0)

        // Append one second of audio in two half-second buffers.
        writer.append(try makeBuffer(seconds: 0.5))
        writer.append(try makeBuffer(seconds: 0.5))
        writer.finish()

        XCTAssertTrue(writer.hasContent)
        // Elapsed tracks written frames / sample rate: about one second.
        XCTAssertEqual(writer.elapsedSeconds, 1.0, accuracy: 0.05)
        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.url.path))
        // The file is a real, non-empty AAC recording.
        let size = try FileManager.default.attributesOfItem(atPath: writer.url.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0)
    }

    func testDiscardRemovesFile() throws {
        let writer = RecordingWriter()
        writer.append(try makeBuffer(seconds: 0.25))
        writer.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.url.path))
        writer.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.url.path))
    }

    func testEmptyWriterHasNoContent() {
        let writer = RecordingWriter()
        defer { writer.discard() }
        writer.finish()
        XCTAssertFalse(writer.hasContent)
    }

    // MARK: - RecordingTiming: relative range + absolute offset math

    func testRelativeRangeSpansFirstStartToLastEnd() {
        let range = RecordingTiming.relativeRange(firstStart: 0.5, lastStart: 2.0, lastDuration: 1.0)
        XCTAssertEqual(range?.start, 0.5)
        XCTAssertEqual(range?.duration, 2.5) // 2.0 + 1.0 - 0.5
    }

    func testRelativeRangeZeroSpanIsNilForTextOnlyFallback() {
        // All-zero timings (the recognizer reported no timing) yield nil, so the paragraph is
        // treated as text-only rather than getting a bogus 0.0 range.
        XCTAssertNil(RecordingTiming.relativeRange(firstStart: 0, lastStart: 0, lastDuration: 0))
    }

    func testAbsoluteAddsRequestOffsetToRelativeStart() {
        // The core restart-offset mapping: a segment timed at 1.5s into its request, on a request
        // that began 10s into the recording, maps to an absolute 11.5s.
        let timing = RecordingTiming.absolute(offset: 10.0, relative: (start: 1.5, duration: 2.0))
        XCTAssertEqual(timing?.start, 11.5)
        XCTAssertEqual(timing?.duration, 2.0)
    }

    func testAbsoluteAcrossASimulatedRestartKeepsParagraphsOnTheOneTimeline() {
        // Request 1 begins at recording offset 0; its paragraph is timed 0.0-2.0.
        let first = RecordingTiming.absolute(
            offset: 0,
            relative: RecordingTiming.relativeRange(firstStart: 0.0, lastStart: 1.5, lastDuration: 0.5)
        )
        // The recognizer restarts after ~5s of recording; request 2's clock resets to zero, so its
        // paragraph timed 0.0-3.0 must anchor to absolute 5.0, NOT 0.0. A dropped offset would put it
        // back at the start of the recording - exactly the regression this guards.
        let second = RecordingTiming.absolute(
            offset: 5.0,
            relative: RecordingTiming.relativeRange(firstStart: 0.0, lastStart: 2.5, lastDuration: 0.5)
        )
        XCTAssertEqual(first?.start, 0.0)
        XCTAssertEqual(second?.start, 5.0)
        XCTAssertEqual(second?.duration, 3.0)
    }

    func testAbsoluteWithNoRelativeRangeIsNil() {
        XCTAssertNil(RecordingTiming.absolute(offset: 4.0, relative: nil))
    }

    // MARK: - RecordingTiming: resume timing offset (feedback 0022)

    func testOffsetResumedTimingsShiftsOnlyNewParagraphsPastExisting() {
        // Two pre-existing paragraphs (timed against the original recording), then two newly-recorded
        // paragraphs timed against the NEW segment (starting at ~0). After concatenation the original
        // occupies 12.0s, so only the two new paragraphs shift right by 12.0; the old ones are untouched.
        let timings = [
            ParagraphTiming(start: 0.0, duration: 5.0),   // existing #1
            ParagraphTiming(start: 5.0, duration: 7.0),   // existing #2
            ParagraphTiming(start: 0.0, duration: 3.0),   // new #1 (new-segment-relative)
            ParagraphTiming(start: 3.0, duration: 2.0),   // new #2
        ]
        let offset = RecordingTiming.offsetResumedTimings(
            timings, existingParagraphCount: 2, existingDuration: 12.0)

        XCTAssertEqual(offset.count, timings.count, "count and 1:1 alignment preserved")
        // Pre-existing timings unchanged.
        XCTAssertEqual(offset[0], ParagraphTiming(start: 0.0, duration: 5.0))
        XCTAssertEqual(offset[1], ParagraphTiming(start: 5.0, duration: 7.0))
        // New timings anchored after the existing audio (12.0 + relative start).
        XCTAssertEqual(offset[2], ParagraphTiming(start: 12.0, duration: 3.0))
        XCTAssertEqual(offset[3], ParagraphTiming(start: 15.0, duration: 2.0))
    }

    func testOffsetResumedTimingsLeavesZeroLengthPlaceholderInPlace() {
        // A new paragraph that is a zero-length placeholder (text-only, e.g. a folded partial) has no real
        // position, so shifting it would fabricate one. It stays put; a real new paragraph still shifts.
        let timings = [
            ParagraphTiming(start: 0.0, duration: 4.0),   // existing
            ParagraphTiming(start: 0.0, duration: 0.0),   // new, text-only placeholder
            ParagraphTiming(start: 1.0, duration: 2.0),   // new, real range
        ]
        let offset = RecordingTiming.offsetResumedTimings(
            timings, existingParagraphCount: 1, existingDuration: 4.0)

        XCTAssertEqual(offset[0], ParagraphTiming(start: 0.0, duration: 4.0), "existing untouched")
        XCTAssertEqual(offset[1], ParagraphTiming(start: 0.0, duration: 0.0), "placeholder not fabricated")
        XCTAssertEqual(offset[2], ParagraphTiming(start: 5.0, duration: 2.0), "real new range shifted")
    }

    func testOffsetResumedTimingsIsNoOpForNonPositiveExistingDuration() {
        // No existing audio to sit past (a degenerate/zero duration): nothing shifts.
        let timings = [ParagraphTiming(start: 0.0, duration: 2.0), ParagraphTiming(start: 2.0, duration: 1.0)]
        XCTAssertEqual(
            RecordingTiming.offsetResumedTimings(timings, existingParagraphCount: 1, existingDuration: 0),
            timings)
    }

    func testOffsetResumedTimingsWithNoNewParagraphsIsUnchanged() {
        // existingParagraphCount == timings.count: every paragraph pre-dates the resume, nothing to shift.
        let timings = [ParagraphTiming(start: 0.0, duration: 2.0), ParagraphTiming(start: 2.0, duration: 1.0)]
        XCTAssertEqual(
            RecordingTiming.offsetResumedTimings(timings, existingParagraphCount: 2, existingDuration: 9.0),
            timings)
    }

    // MARK: - DictationViewModel.remapNewParagraphsOntoSegment (feedback 0022, engineer review)

    func testRemapNewParagraphsRemapsOnlyTheNewSliceByTheSegmentRemovedRanges() {
        // One pre-existing paragraph (into the original recording) + two new (into the new segment). The
        // trim removed [1.0, 3.0) (2s) from the NEW segment. Only the new paragraphs after that silence
        // shift left; the pre-existing paragraph's range into the original recording is NOT touched.
        let timings = [
            ParagraphTiming(start: 0.0, duration: 4.0),  // existing (into original recording)
            ParagraphTiming(start: 0.5, duration: 0.5),  // new, before the cut -> unshifted
            ParagraphTiming(start: 5.0, duration: 1.0),  // new, after the 2s cut -> shifts left 2s
        ]
        let out = DictationViewModel.remapNewParagraphsOntoSegment(
            timings, existingParagraphCount: 1,
            removedRanges: [SilenceTrimmer.KeepRange(start: 1.0, end: 3.0)])

        XCTAssertEqual(out[0], ParagraphTiming(start: 0.0, duration: 4.0), "existing NOT remapped")
        XCTAssertEqual(out[1], ParagraphTiming(start: 0.5, duration: 0.5), "new before the cut unshifted")
        XCTAssertEqual(out[2], ParagraphTiming(start: 3.0, duration: 1.0), "new after the cut shifts left 2s")
    }

    func testRemapNewParagraphsIsNoOpWhenNothingRemoved() {
        let timings = [ParagraphTiming(start: 0.0, duration: 2.0), ParagraphTiming(start: 3.0, duration: 1.0)]
        XCTAssertEqual(
            DictationViewModel.remapNewParagraphsOntoSegment(timings, existingParagraphCount: 1, removedRanges: []),
            timings)
    }

    /// Build a buffer of `seconds` of silence at the writer's expected format.
    private func makeBuffer(seconds: Double) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        // Leave the samples at zero (silence); the writer only cares about frame counts and bytes.
        return buffer
    }
}
