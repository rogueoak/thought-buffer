import XCTest
@testable import ThoughtStream

/// The pure playback-progress math for the bottom player and Now Playing scrubber (spec 0027): the
/// seek/skip clamp, the progress fraction, and the elapsed/remaining time labels. Proven here without
/// audio or a controller so the tunable / formatting logic has a CI gate even though the live audio,
/// Now Playing, and Dynamic Island are device-only.
final class PlaybackProgressTests: XCTestCase {

    // MARK: - clamp to [0, duration]

    func testClampInRangeIsUnchanged() {
        XCTAssertEqual(PlaybackProgress.clamp(5, duration: 12), 5)
    }

    func testClampPastEndPinsToDuration() {
        XCTAssertEqual(PlaybackProgress.clamp(999, duration: 12), 12, "a skip/seek past the end clamps to duration")
    }

    func testClampBeforeStartPinsToZero() {
        XCTAssertEqual(PlaybackProgress.clamp(-50, duration: 12), 0, "a skip/seek before 0 clamps to 0")
    }

    func testClampAtBoundariesIsUnchanged() {
        XCTAssertEqual(PlaybackProgress.clamp(0, duration: 12), 0)
        XCTAssertEqual(PlaybackProgress.clamp(12, duration: 12), 12)
    }

    func testClampWithNonPositiveDurationIsZero() {
        XCTAssertEqual(PlaybackProgress.clamp(5, duration: 0), 0)
        XCTAssertEqual(PlaybackProgress.clamp(5, duration: -3), 0)
        XCTAssertEqual(PlaybackProgress.clamp(5, duration: .nan), 0)
    }

    // MARK: - progress fraction

    func testFractionMidway() {
        XCTAssertEqual(PlaybackProgress.fraction(elapsed: 6, duration: 12), 0.5, accuracy: 0.0001)
    }

    func testFractionClampsAndGuardsDuration() {
        XCTAssertEqual(PlaybackProgress.fraction(elapsed: 0, duration: 12), 0)
        XCTAssertEqual(PlaybackProgress.fraction(elapsed: 12, duration: 12), 1)
        XCTAssertEqual(PlaybackProgress.fraction(elapsed: 20, duration: 12), 1, "over-elapsed clamps to 1")
        XCTAssertEqual(PlaybackProgress.fraction(elapsed: -1, duration: 12), 0, "negative clamps to 0")
        XCTAssertEqual(PlaybackProgress.fraction(elapsed: 5, duration: 0), 0, "no duration reads 0, not NaN")
    }

    // MARK: - elapsed label (delegates to Thought.durationLabel)

    func testElapsedLabelFormats() {
        XCTAssertEqual(PlaybackProgress.elapsedLabel(0), "0:00")
        XCTAssertEqual(PlaybackProgress.elapsedLabel(9), "0:09")
        XCTAssertEqual(PlaybackProgress.elapsedLabel(84), "1:24")
    }

    func testElapsedLabelRollsOverAnHour() {
        XCTAssertEqual(PlaybackProgress.elapsedLabel(3723), "1:02:03", "past an hour reads h:mm:ss")
    }

    // MARK: - remaining (countdown) label

    func testRemainingLabelCountsDown() {
        XCTAssertEqual(PlaybackProgress.remainingLabel(elapsed: 0, duration: 84), "-1:24")
        XCTAssertEqual(PlaybackProgress.remainingLabel(elapsed: 9, duration: 84), "-1:15")
    }

    func testRemainingLabelAtOrPastEndIsZero() {
        XCTAssertEqual(PlaybackProgress.remainingLabel(elapsed: 84, duration: 84), "-0:00")
        XCTAssertEqual(PlaybackProgress.remainingLabel(elapsed: 200, duration: 84), "-0:00", "past the end never goes positive")
    }
}
