import XCTest
@testable import ThoughtStream

/// The detail-view playback model (spec 0007): simple play / stop of a saved note's recording via a
/// stubbed `AudioNotePlayer`, so range/full playback and the toggle state are proven without audio.
@MainActor
final class NotePlaybackModelTests: XCTestCase {

    func testNoAudioHidesPlayback() {
        let model = NotePlaybackModel(audioURL: nil, player: StubAudioNotePlayer())
        XCTAssertFalse(model.canPlay)
        XCTAssertFalse(model.isPlaying)
    }

    func testTogglePlaysWholeRecordingFromStart() {
        let url = URL(fileURLWithPath: "/tmp/rec.m4a")
        let player = StubAudioNotePlayer()
        let model = NotePlaybackModel(audioURL: url, player: player)

        XCTAssertTrue(model.canPlay)
        model.toggle()

        // Full-note playback: from 0, no duration (plays to the end).
        XCTAssertEqual(player.plays.count, 1)
        XCTAssertEqual(player.plays.first?.url, url)
        XCTAssertEqual(player.plays.first?.start, 0)
        XCTAssertNil(player.plays.first?.duration)
        XCTAssertTrue(model.isPlaying)
    }

    func testToggleWhilePlayingStops() {
        let player = StubAudioNotePlayer()
        let model = NotePlaybackModel(audioURL: URL(fileURLWithPath: "/tmp/rec.m4a"), player: player)
        model.toggle()
        XCTAssertTrue(model.isPlaying)

        model.toggle()
        XCTAssertEqual(player.stopCount, 1)
        XCTAssertFalse(model.isPlaying)
    }

    func testPlaybackFinishClearsPlayingState() {
        let player = StubAudioNotePlayer()
        let model = NotePlaybackModel(audioURL: URL(fileURLWithPath: "/tmp/rec.m4a"), player: player)
        model.toggle()
        XCTAssertTrue(model.isPlaying)

        // The player reaching the end (onFinish) resets the button.
        player.finish()
        XCTAssertFalse(model.isPlaying)
    }

    func testPlayFailureLeavesNotPlaying() {
        let player = StubAudioNotePlayer()
        player.playSucceeds = false
        let model = NotePlaybackModel(audioURL: URL(fileURLWithPath: "/tmp/rec.m4a"), player: player)
        model.toggle()
        // An unplayable file leaves the model idle rather than stuck "playing".
        XCTAssertFalse(model.isPlaying)
    }
}

/// Records what was played and lets the test drive the finish callback.
@MainActor
private final class StubAudioNotePlayer: AudioNotePlayer {
    var onFinish: (() -> Void)?
    var playSucceeds = true
    private(set) var plays: [(url: URL, start: Double, duration: Double?)] = []
    private(set) var stopCount = 0

    @discardableResult
    func play(url: URL, from start: Double, duration: Double?) -> Bool {
        plays.append((url, start, duration))
        return playSucceeds
    }

    func stop() { stopCount += 1 }
    func finish() { onFinish?() }
}
