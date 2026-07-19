import Foundation

/// Decides, per finalized speech segment, whether it continues the CURRENT paragraph or starts a
/// NEW one (feedback 0012). This replaces the old "one finalized result = one paragraph" rule, which
/// broke a single spoken sentence into several paragraphs whenever the iOS 26 transcriber finalized
/// on a short mid-thought breath. Grouping like the native Notes app - flow through a breath, break
/// only on a real silence - is the whole fix.
///
/// The decision is based purely on the SILENCE GAP between the previous segment's end and the new
/// segment's start, both in analysis-relative seconds (from the transcriber's `CMTimeRange`, which is
/// present even for a text-only session because it is relative to analysis start, not to any audio
/// tee). Keeping ALL of the policy here - a pure value type with no Speech / AVFoundation import -
/// makes it trivially unit-testable and keeps the view model a thin caller.
struct ParagraphGrouper {
    /// A grouping decision for one finalized segment.
    enum Decision: Equatable {
        /// Start a new paragraph with this segment.
        case newParagraph
        /// Append this segment to the current (last) paragraph.
        case appendToCurrent
    }

    /// The silence gap, in seconds, at or above which a new segment starts a NEW paragraph; below it,
    /// the segment flows into the current paragraph. Default 1.5s: long enough to ride through a
    /// mid-thought breath, short enough that a deliberate pause between distinct thoughts still breaks.
    ///
    /// DEVICE-TUNABLE: this is the single lever for how eagerly dictation breaks paragraphs. The
    /// feedback doc defers final tuning to a device pass, so it lives here as one named constant that a
    /// later device session can adjust in one place.
    static let defaultGapThreshold: Double = 1.5

    private let gapThreshold: Double

    /// The analysis-relative end (start + duration, in seconds) of the last segment we grouped, or nil
    /// before the first segment. Reset whenever a paragraph boundary is forced so the next gap is
    /// computed from the right anchor.
    private var lastEnd: Double?

    init(gapThreshold: Double = ParagraphGrouper.defaultGapThreshold) {
        self.gapThreshold = gapThreshold
    }

    /// Decide how to place a finalized segment, and advance the running "last end".
    ///
    /// - `isAnalysisStart`: true for the FIRST finalized result of an analysis. Analysis time resets to
    ///   ~0 across a pause/resume seam, so the segment after a resume would otherwise compute a bogus
    ///   negative gap against the previous analysis's end. Treating an analysis start as an unconditional
    ///   boundary keeps a resume honest (a resume is a deliberate break) and never mis-merges across it.
    /// - A non-finite or negative duration (a degenerate range) is treated as a new paragraph rather
    ///   than propagating a bad number into the running end, so a malformed range never crashes or
    ///   silently corrupts the gap math for following segments.
    mutating func decide(
        startSeconds: Double,
        durationSeconds: Double,
        isAnalysisStart: Bool
    ) -> Decision {
        // A degenerate range cannot anchor a gap: break here and drop the running end so the NEXT
        // segment also starts fresh rather than measuring a gap against a non-finite anchor.
        guard startSeconds.isFinite, durationSeconds.isFinite, durationSeconds >= 0 else {
            lastEnd = nil
            return .newParagraph
        }

        // A fresh analysis, or the very first segment, is always a boundary. Anchor the running end at
        // this segment's end so the FOLLOWING segment's gap is measured from here.
        if isAnalysisStart || lastEnd == nil {
            lastEnd = startSeconds + durationSeconds
            return .newParagraph
        }

        let gap = startSeconds - (lastEnd ?? startSeconds)
        lastEnd = startSeconds + durationSeconds
        return gap >= gapThreshold ? .newParagraph : .appendToCurrent
    }
}
