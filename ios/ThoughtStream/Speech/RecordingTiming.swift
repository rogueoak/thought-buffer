import Foundation

/// Pure timing math for mapping a finalized segment to its range in the recording (spec 0007).
///
/// Split out from the speech service so it is unit-testable without an `SFTranscriptionSegment`
/// (which has no public initializer): the service pulls the raw `timestamp`/`duration` numbers off
/// the segments and calls these, so the restart-offset logic - the part that actually broke if it
/// regressed - is provable with plain doubles.
enum RecordingTiming {
    /// The request-relative range spanned by a transcription's segments, from the first segment's
    /// start to the last segment's end, or nil when there is nothing to time.
    ///
    /// `SFTranscriptionSegment.timestamp`/`duration` are seconds from the START of the recognition
    /// request. Some results report all-zero timestamps (no timing available); a zero-length range is
    /// not a real position, so it returns nil and the caller treats the paragraph as text-only.
    static func relativeRange(
        firstStart: Double,
        lastStart: Double,
        lastDuration: Double
    ) -> (start: Double, duration: Double)? {
        let end = lastStart + lastDuration
        guard end > firstStart else { return nil }
        return (firstStart, end - firstStart)
    }

    /// Anchor an analysis-relative range to absolute recording time by adding the offset captured when
    /// the analysis began (the recording seconds elapsed at that point). A finalized result's
    /// `CMTimeRange` is relative to the analysis start, and analysis restarts on resume while the
    /// recording file is continuous, so this offset keeps a paragraph's range pointing at the right
    /// place in the ONE continuous recording across a pause/resume seam. Returns nil when there is no
    /// relative range.
    static func absolute(
        offset: Double,
        relative: (start: Double, duration: Double)?
    ) -> ParagraphTiming? {
        guard let relative else { return nil }
        return ParagraphTiming(start: offset + relative.start, duration: relative.duration)
    }

    /// Offset the timings of paragraphs recorded AFTER a resume so they sit past the existing recording
    /// on the ONE concatenated timeline (feedback 0022).
    ///
    /// When a thought that already has audio is resumed with recording on, the new audio is captured to
    /// its OWN segment file (its analysis clock starts at ~0) and then concatenated onto the thought's
    /// existing `.m4a`. So the newly-recorded paragraphs are timed relative to the NEW segment's start,
    /// but after concatenation they actually begin `existingDuration` seconds into the combined file.
    /// This shifts each NEW timing right by `existingDuration`; the PRE-EXISTING paragraphs' timings are
    /// untouched (they still point at the original audio, which sits unchanged at the front of the
    /// concatenation). A zero-length placeholder (a text-only paragraph, `duration == 0`) is left exactly
    /// where it is - it carries no real position, so shifting it would fabricate one and mislead playback.
    ///
    /// Pure and count-preserving: `timings.count` in == out and each index maps to the same paragraph, so
    /// the caller's `paragraphs`/`timings` 1:1 alignment invariant is preserved. `existingDuration` is the
    /// original recording's `recordingDuration`; a non-positive value is a no-op (nothing to shift past).
    ///
    /// - Parameters:
    ///   - timings: the full paragraph timings, pre-existing paragraphs FIRST then the newly-recorded ones.
    ///   - existingParagraphCount: how many leading paragraphs pre-date the resume (kept as-is).
    ///   - existingDuration: the seconds the pre-existing recording occupies at the front of the join.
    static func offsetResumedTimings(
        _ timings: [ParagraphTiming],
        existingParagraphCount: Int,
        existingDuration: Double
    ) -> [ParagraphTiming] {
        guard existingDuration > 0, existingParagraphCount >= 0 else { return timings }
        return timings.enumerated().map { index, timing in
            guard index >= existingParagraphCount else { return timing }
            // A zero-length placeholder has no real position - leave it, do not fabricate one.
            guard timing.duration > 0 else { return timing }
            return ParagraphTiming(start: timing.start + existingDuration, duration: timing.duration)
        }
    }
}
