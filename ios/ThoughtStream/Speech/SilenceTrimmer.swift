import Foundation

/// Pure silence analysis for automatic dead-air removal (spec 0019).
///
/// Given a sequence of per-window RMS levels (each window covering a fixed slice of audio time) and
/// the window duration, this returns the time-ranges to KEEP: the complement of every silence run
/// longer than `minPauseSeconds`, with each trimmed silence shortened to leave a short natural
/// "breath" gap (`breathGapSeconds`) so the result never sounds hard-spliced. No AVFoundation here -
/// it operates on plain numbers, so every edge (silence at start / middle / end, back-to-back
/// silences, no silence, entire clip silent, a sub-threshold pause) is unit-testable without audio.
///
/// LOAD-BEARING INVARIANT (feedback 0012, spec 0019): `minPauseSeconds` (2.0s) MUST stay strictly
/// ABOVE `ParagraphGrouper.defaultGapThreshold` (1.5s). Any silence long enough to trim is then
/// always a paragraph boundary, never an interior sub-threshold silence inside a merged paragraph, so
/// trimming only ever removes time BETWEEN paragraphs and the merged `[start, duration]` timings stay
/// remappable by shifting paragraph starts (see `TimingRemapper`). A guard test asserts the coupling.
enum SilenceTrimmer {
    /// RMS amplitude at or below which a window counts as silence. Float PCM is roughly 0...1, and a
    /// quiet room / breath sits well under this; normal speech rides far above it. Conservative on
    /// purpose: better to leave a marginal pause in than to clip the quiet tail of a word.
    static let silenceFloor: Float = 0.015

    /// A silence run must exceed this many seconds to be trimmed at all. Below it, the pause is kept
    /// verbatim. 2.0s by the spec. MUST stay strictly above `ParagraphGrouper.defaultGapThreshold`.
    static let minPauseSeconds: Double = 2.0

    /// The natural gap left behind after trimming a silence, so speech resumes with a breath rather
    /// than a hard cut. ~0.6s by the spec. A trimmed silence is reduced to exactly this length; a
    /// silence at or below `minPauseSeconds` is never touched.
    static let breathGapSeconds: Double = 0.6

    /// A half-open time range `[start, end)` in seconds to keep in the trimmed output.
    struct KeepRange: Equatable {
        let start: Double
        let end: Double

        var duration: Double { end - start }
    }

    /// Compute the KEEP ranges for a clip described by `windowRMS` (one RMS value per fixed-duration
    /// window) and `windowSeconds` (each window's length in seconds).
    ///
    /// The whole clip spans `[0, windowRMS.count * windowSeconds)`. A maximal run of consecutive
    /// silent windows longer than `minPauseSeconds` is a trimmable silence: its middle is dropped and
    /// only `breathGapSeconds` of it is kept (split evenly on both sides of the cut, so the gap sits
    /// where the silence was rather than jammed against the following word). Everything else - speech,
    /// and any sub-threshold pause - is kept verbatim.
    ///
    /// Adjacent kept ranges are coalesced, so the result is a minimal ordered list of non-overlapping
    /// ranges. An entirely-silent clip returns an empty list (nothing to keep); a clip with no
    /// trimmable silence returns a single full-span range.
    static func keepRanges(
        windowRMS: [Float],
        windowSeconds: Double,
        silenceFloor: Float = SilenceTrimmer.silenceFloor,
        minPauseSeconds: Double = SilenceTrimmer.minPauseSeconds,
        breathGapSeconds: Double = SilenceTrimmer.breathGapSeconds
    ) -> [KeepRange] {
        guard windowSeconds > 0, !windowRMS.isEmpty else { return [] }

        let totalDuration = Double(windowRMS.count) * windowSeconds

        // An entirely-silent clip has no speech to tighten around, so trimming it to a breath-gap stub
        // would be pointless (and risks replacing a real recording with a near-empty file). Keep it
        // whole and let the caller leave the original untouched (its `removedRanges` is then empty).
        let hasSpeech = windowRMS.contains { $0.isFinite && $0 > silenceFloor }
        guard hasSpeech else { return [KeepRange(start: 0, end: totalDuration)] }

        // Runs of consecutive silent windows, as half-open [startIndex, endIndex) window ranges.
        let silentRuns = silentWindowRuns(windowRMS: windowRMS, silenceFloor: silenceFloor)

        // Turn each long-enough silent run into a DROP interval (the portion of it we remove), then
        // KEEP is the complement of the drops within [0, totalDuration).
        var drops: [(start: Double, end: Double)] = []
        for run in silentRuns {
            let runStart = Double(run.start) * windowSeconds
            let runEnd = Double(run.end) * windowSeconds
            let runLength = runEnd - runStart
            guard runLength > minPauseSeconds else { continue }
            // Keep `breathGapSeconds` total (half at each end of the silence), drop the middle.
            let keep = min(breathGapSeconds, runLength)
            let half = keep / 2
            let dropStart = runStart + half
            let dropEnd = runEnd - half
            if dropEnd > dropStart {
                drops.append((start: dropStart, end: dropEnd))
            }
        }

        return keepComplement(ofDrops: drops, totalDuration: totalDuration)
    }

    /// Maximal runs of consecutive windows at or below the silence floor, as half-open window-index
    /// ranges `[start, end)`. A non-finite RMS is treated as silence (a degenerate window is not
    /// speech we want to protect).
    private static func silentWindowRuns(windowRMS: [Float], silenceFloor: Float) -> [(start: Int, end: Int)] {
        var runs: [(start: Int, end: Int)] = []
        var runStart: Int?
        for (index, rms) in windowRMS.enumerated() {
            let isSilent = !rms.isFinite || rms <= silenceFloor
            if isSilent {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                runs.append((start: start, end: index))
                runStart = nil
            }
        }
        if let start = runStart {
            runs.append((start: start, end: windowRMS.count))
        }
        return runs
    }

    /// The complement of `drops` within `[0, totalDuration)`, coalesced into a minimal ordered list of
    /// keep ranges. `drops` are assumed ordered and non-overlapping (they come from disjoint silent
    /// runs). A zero-length keep gap between two adjacent drops is skipped.
    private static func keepComplement(
        ofDrops drops: [(start: Double, end: Double)],
        totalDuration: Double
    ) -> [KeepRange] {
        var ranges: [KeepRange] = []
        var cursor = 0.0
        for drop in drops {
            if drop.start > cursor {
                ranges.append(KeepRange(start: cursor, end: drop.start))
            }
            cursor = max(cursor, drop.end)
        }
        if totalDuration > cursor {
            ranges.append(KeepRange(start: cursor, end: totalDuration))
        }
        return ranges
    }

    /// The removed time-ranges (in ORIGINAL-timeline seconds) implied by a set of keep ranges over a
    /// clip of `totalDuration`. This is the complement of the keeps and is what `TimingRemapper`
    /// consumes to shift paragraph starts. Returned ordered and non-overlapping.
    static func removedRanges(keepRanges: [KeepRange], totalDuration: Double) -> [KeepRange] {
        guard totalDuration > 0 else { return [] }
        var removed: [KeepRange] = []
        var cursor = 0.0
        for keep in keepRanges.sorted(by: { $0.start < $1.start }) {
            if keep.start > cursor {
                removed.append(KeepRange(start: cursor, end: keep.start))
            }
            cursor = max(cursor, keep.end)
        }
        if totalDuration > cursor {
            removed.append(KeepRange(start: cursor, end: totalDuration))
        }
        return removed
    }
}
