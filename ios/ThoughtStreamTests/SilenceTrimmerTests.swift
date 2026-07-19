import XCTest
@testable import ThoughtStream

/// The pure silence analyzer (spec 0019). Given windowed RMS + a window duration, it returns the
/// KEEP ranges: the complement of silences longer than the min-pause threshold, each trimmed to a
/// short breath gap. All edges are provable with plain numbers, no audio.
final class SilenceTrimmerTests: XCTestCase {
    private let window = 0.1 // 100ms windows
    private let loud: Float = 0.5
    private let quiet: Float = 0.0

    /// Build a window array: `speech` loud windows, then `silence` quiet windows, repeated per pair.
    private func windows(_ segments: [(loud: Int, quiet: Int)]) -> [Float] {
        var out: [Float] = []
        for seg in segments {
            out.append(contentsOf: Array(repeating: loud, count: seg.loud))
            out.append(contentsOf: Array(repeating: quiet, count: seg.quiet))
        }
        return out
    }

    // MARK: - Load-bearing invariant

    func testMinPauseStaysStrictlyAboveParagraphGapThreshold() {
        // The whole remap correctness rests on this: a trimmable silence is always a paragraph
        // boundary, never interior. If a future change lowers the trim floor below the group
        // threshold, revisit range merging (see ParagraphGrouper's LOAD-BEARING COUPLING note).
        XCTAssertGreaterThan(SilenceTrimmer.minPauseSeconds, ParagraphGrouper.defaultGapThreshold)
    }

    // MARK: - No silence

    func testNoSilenceKeepsWholeClip() {
        let rms = Array(repeating: loud, count: 50) // 5s of speech, no pause
        let keeps = SilenceTrimmer.keepRanges(windowRMS: rms, windowSeconds: window)
        XCTAssertEqual(keeps.count, 1)
        XCTAssertEqual(keeps.first?.start ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(keeps.first?.end ?? -1, 5.0, accuracy: 0.001)
    }

    func testSubThresholdSilenceIsKept() {
        // A 1.5s pause (below the 2.0s min) must NOT be trimmed: the clip is kept whole.
        let rms = windows([(loud: 10, quiet: 15), (loud: 10, quiet: 0)]) // 1s speech, 1.5s pause, 1s speech
        let keeps = SilenceTrimmer.keepRanges(windowRMS: rms, windowSeconds: window)
        XCTAssertEqual(keeps.count, 1)
        XCTAssertEqual(keeps.first?.end ?? -1, 3.5, accuracy: 0.001)
    }

    func testSilenceExactlyAtMinPauseIsKept() {
        // The trim is a STRICT `runLength > minPauseSeconds`, so a silence EXACTLY at the 2.0s floor is
        // NOT trimmed - the on/off boundary. 1s speech, exactly 2.0s pause, 1s speech -> kept whole.
        let rms = windows([(loud: 10, quiet: 20), (loud: 10, quiet: 0)])
        let keeps = SilenceTrimmer.keepRanges(windowRMS: rms, windowSeconds: window)
        XCTAssertEqual(keeps.count, 1, "a silence exactly at the min-pause floor is kept, not trimmed")
        XCTAssertEqual(keeps.first?.end ?? -1, 4.0, accuracy: 0.001)
    }

    func testSilenceJustOverMinPauseIsTrimmed() {
        // Just over the floor (2.1s pause) IS trimmed - the other side of the boundary.
        let rms = windows([(loud: 10, quiet: 21), (loud: 10, quiet: 0)])
        let keeps = SilenceTrimmer.keepRanges(windowRMS: rms, windowSeconds: window)
        XCTAssertEqual(keeps.count, 2, "a silence just over the floor is trimmed")
    }

    // MARK: - Silence in the middle

    func testMidClipSilenceTrimmedToBreathGap() {
        // 1s speech, 3s silence, 1s speech. The 3s pause > 2s min, so it is cut to a 0.6s breath gap.
        let rms = windows([(loud: 10, quiet: 30), (loud: 10, quiet: 0)])
        let keeps = SilenceTrimmer.keepRanges(windowRMS: rms, windowSeconds: window)
        // Expect two keep ranges with a 0.6s gap between: [0,1.3) and [3.7,5.0). The silence spans
        // [1.0,4.0); breath gap 0.6 split -> drop [1.3,3.7).
        XCTAssertEqual(keeps.count, 2)
        XCTAssertEqual(keeps[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(keeps[0].end, 1.3, accuracy: 0.001)
        XCTAssertEqual(keeps[1].start, 3.7, accuracy: 0.001)
        XCTAssertEqual(keeps[1].end, 5.0, accuracy: 0.001)

        // The removed range is the dropped middle of the silence.
        let removed = SilenceTrimmer.removedRanges(keepRanges: keeps, totalDuration: 5.0)
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed[0].start, 1.3, accuracy: 0.001)
        XCTAssertEqual(removed[0].end, 3.7, accuracy: 0.001)
    }

    // MARK: - Silence at the start

    func testLeadingSilenceTrimmed() {
        // 3s leading silence, then 2s speech. The pause is at the very front.
        let rms = windows([(loud: 0, quiet: 30), (loud: 20, quiet: 0)])
        let keeps = SilenceTrimmer.keepRanges(windowRMS: rms, windowSeconds: window)
        // Silence [0,3.0); drop [0.3,2.7); keep [0,0.3) + [2.7,5.0).
        XCTAssertEqual(keeps.count, 2)
        XCTAssertEqual(keeps[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(keeps[0].end, 0.3, accuracy: 0.001)
        XCTAssertEqual(keeps[1].start, 2.7, accuracy: 0.001)
        XCTAssertEqual(keeps[1].end, 5.0, accuracy: 0.001)
    }

    // MARK: - Silence at the end

    func testTrailingSilenceTrimmed() {
        // 2s speech, then 3s trailing silence.
        let rms = windows([(loud: 20, quiet: 30)])
        let keeps = SilenceTrimmer.keepRanges(windowRMS: rms, windowSeconds: window)
        // Silence [2.0,5.0); drop [2.3,4.7); keep [0,2.3) + [4.7,5.0).
        XCTAssertEqual(keeps.count, 2)
        XCTAssertEqual(keeps[0].end, 2.3, accuracy: 0.001)
        XCTAssertEqual(keeps[1].start, 4.7, accuracy: 0.001)
        XCTAssertEqual(keeps[1].end, 5.0, accuracy: 0.001)
    }

    // MARK: - Back-to-back silences

    func testBackToBackSilencesEachTrimmed() {
        // speech(1s) silence(3s) speech(1s) silence(2.5s) speech(1s). Two trimmable silences.
        let rms = windows([(loud: 10, quiet: 30), (loud: 10, quiet: 25), (loud: 10, quiet: 0)])
        let keeps = SilenceTrimmer.keepRanges(windowRMS: rms, windowSeconds: window)
        // First silence [1,4) -> drop [1.3,3.7). Second silence [5,7.5) -> drop [5.3,7.2).
        // Keeps: [0,1.3), [3.7,5.3), [7.2,8.5).
        XCTAssertEqual(keeps.count, 3)
        XCTAssertEqual(keeps[0].end, 1.3, accuracy: 0.001)
        XCTAssertEqual(keeps[1].start, 3.7, accuracy: 0.001)
        XCTAssertEqual(keeps[1].end, 5.3, accuracy: 0.001)
        XCTAssertEqual(keeps[2].start, 7.2, accuracy: 0.001)
        XCTAssertEqual(keeps[2].end, 8.5, accuracy: 0.001)

        let removed = SilenceTrimmer.removedRanges(keepRanges: keeps, totalDuration: 8.5)
        XCTAssertEqual(removed.count, 2)
        XCTAssertEqual(removed[0].start, 1.3, accuracy: 0.001)
        XCTAssertEqual(removed[0].end, 3.7, accuracy: 0.001)
        XCTAssertEqual(removed[1].start, 5.3, accuracy: 0.001)
        XCTAssertEqual(removed[1].end, 7.2, accuracy: 0.001)
    }

    // MARK: - Entire clip silent

    func testEntirelySilentClipIsKeptWhole() {
        let rms = Array(repeating: quiet, count: 50) // 5s of silence
        let keeps = SilenceTrimmer.keepRanges(windowRMS: rms, windowSeconds: window)
        // An all-silent clip has no speech to tighten around, so by policy it is kept WHOLE (one range)
        // rather than trimmed to a breath-gap stub; the removed set is then empty and the caller leaves
        // the original file untouched.
        XCTAssertEqual(keeps.count, 1)
        XCTAssertEqual(keeps[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(keeps[0].end, 5.0, accuracy: 0.001)
        let removed = SilenceTrimmer.removedRanges(keepRanges: keeps, totalDuration: 5.0)
        XCTAssertTrue(removed.isEmpty)
    }

    // MARK: - Degenerate input

    func testEmptyWindowsReturnsNoRanges() {
        XCTAssertTrue(SilenceTrimmer.keepRanges(windowRMS: [], windowSeconds: window).isEmpty)
    }

    func testZeroWindowSecondsReturnsNoRanges() {
        let rms = Array(repeating: loud, count: 10)
        XCTAssertTrue(SilenceTrimmer.keepRanges(windowRMS: rms, windowSeconds: 0).isEmpty)
    }
}
