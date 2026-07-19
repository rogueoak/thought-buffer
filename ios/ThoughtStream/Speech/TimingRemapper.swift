import Foundation

/// Pure remap of paragraph timings onto the compressed timeline after dead-air removal (spec 0019).
///
/// A `ParagraphTiming` references ABSOLUTE recording time. When `AudioTrimmer` removes silent ranges
/// from a recording, every paragraph that started AFTER some removed silence now sits earlier in the
/// shortened file, so its `start` must be shifted LEFT by the total removed duration that preceded it.
///
/// Durations are left UNCHANGED. This is sound only because of the load-bearing invariant
/// (`SilenceTrimmer.minPauseSeconds` > `ParagraphGrouper.defaultGapThreshold`): a trimmable silence is
/// always a paragraph boundary, so no removed range ever lies INSIDE a paragraph's `[start, duration]`
/// span - it only ever sits in the gap between paragraphs. Therefore each paragraph shifts as a rigid
/// block and its length is preserved. Pure so every case (silence before / between paragraphs, none,
/// back-to-back silences) is unit-testable, and `timings.count` is provably preserved and aligned.
enum TimingRemapper {
    /// Remap `timings` onto the compressed timeline produced by removing `removedRanges` (each an
    /// original-timeline `[start, end)` in seconds). Returns one output per input, in order, with the
    /// same count, so the note's paragraph <-> timing alignment is preserved.
    ///
    /// A timing with a non-positive duration (a zero-length placeholder for a text-only paragraph) is
    /// still shifted so its start stays consistent with its neighbors, but its (zero) duration is kept.
    static func remap(
        timings: [ParagraphTiming],
        removedRanges: [SilenceTrimmer.KeepRange]
    ) -> [ParagraphTiming] {
        guard !removedRanges.isEmpty else { return timings }
        let ordered = removedRanges.sorted { $0.start < $1.start }
        return timings.map { timing in
            let shift = removedDurationBefore(timing.start, removed: ordered)
            let newStart = max(0, timing.start - shift)
            return ParagraphTiming(start: newStart, duration: timing.duration)
        }
    }

    /// The total removed duration that lies strictly BEFORE `time` on the original timeline. A removed
    /// range fully before `time` contributes its whole length; a range straddling `time` contributes
    /// only up to `time` (defensive: by the invariant a removed range never straddles a real paragraph
    /// start, but clamping keeps a boundary case from shifting a start past itself). A range entirely
    /// at or after `time` contributes nothing.
    private static func removedDurationBefore(
        _ time: Double,
        removed: [SilenceTrimmer.KeepRange]
    ) -> Double {
        var total = 0.0
        for range in removed {
            if range.end <= time {
                total += range.duration
            } else if range.start < time {
                total += time - range.start
            } else {
                break
            }
        }
        return total
    }
}
