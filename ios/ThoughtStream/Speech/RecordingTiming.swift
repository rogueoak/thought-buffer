import Foundation

/// Pure timing math for mapping a finalized segment to its range in the recording (spec 0007).
///
/// Split out from `SpeechDictationService` so it is unit-testable without an `SFTranscriptionSegment`
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

    /// Anchor a request-relative range to absolute recording time by adding the offset captured when
    /// the request began (the recording seconds elapsed at that point). Because the recognition
    /// request restarts many times per session and its clock resets each time, this offset is what
    /// keeps a paragraph's range pointing at the right place in the ONE continuous recording. Returns
    /// nil when there is no relative range.
    static func absolute(
        offset: Double,
        relative: (start: Double, duration: Double)?
    ) -> ParagraphTiming? {
        guard let relative else { return nil }
        return ParagraphTiming(start: offset + relative.start, duration: relative.duration)
    }
}
