import XCTest
@testable import ThoughtStream

/// The detail-view playback model (spec 0007): simple play / stop of a saved note's recording via a
/// stubbed `AudioNotePlayer`, so range/full playback and the toggle state are proven without audio.
/// The recording URL is resolved LAZILY (off the main actor at play time) through a stubbed
/// resolver, so these tests also pin that navigation never triggers URL resolution.
@MainActor
final class NotePlaybackModelTests: XCTestCase {

    private let noteID = UUID()

    func testNoAudioHidesPlayback() {
        let resolver = StubResolver(url: nil)
        let model = NotePlaybackModel(
            noteID: noteID, audioFileName: nil, resolver: resolver, player: StubAudioNotePlayer()
        )
        XCTAssertFalse(model.canPlay)
        XCTAssertFalse(model.isPlaying)
    }

    /// Constructing the model must NOT resolve the URL - resolution is deferred to play time so
    /// navigation never blocks on the coordinated presence check.
    func testConstructionDoesNotResolveURL() {
        let resolver = StubResolver(url: URL(fileURLWithPath: "/tmp/rec.m4a"))
        _ = NotePlaybackModel(
            noteID: noteID, audioFileName: "rec.m4a", resolver: resolver, player: StubAudioNotePlayer()
        )
        XCTAssertEqual(resolver.resolveCount, 0, "URL resolution must be lazy, not at construction")
    }

    func testTogglePlaysWholeRecordingFromStart() async {
        let url = URL(fileURLWithPath: "/tmp/rec.m4a")
        let player = StubAudioNotePlayer()
        let resolver = StubResolver(url: url)
        let model = NotePlaybackModel(
            noteID: noteID, audioFileName: "rec.m4a", resolver: resolver, player: player
        )

        XCTAssertTrue(model.canPlay)
        model.toggle()
        await model.settle()

        // The URL was resolved lazily, off-main, at play time.
        XCTAssertEqual(resolver.resolveCount, 1)
        // Full-note playback: from 0, no duration (plays to the end).
        XCTAssertEqual(player.plays.count, 1)
        XCTAssertEqual(player.plays.first?.url, url)
        XCTAssertEqual(player.plays.first?.start, 0)
        XCTAssertNil(player.plays.first?.duration)
        XCTAssertTrue(model.isPlaying)
    }

    func testToggleWhilePlayingStops() async {
        let player = StubAudioNotePlayer()
        let model = NotePlaybackModel(
            noteID: noteID, audioFileName: "rec.m4a",
            resolver: StubResolver(url: URL(fileURLWithPath: "/tmp/rec.m4a")), player: player
        )
        model.toggle()
        await model.settle()
        XCTAssertTrue(model.isPlaying)

        model.toggle()
        XCTAssertEqual(player.stopCount, 1)
        XCTAssertFalse(model.isPlaying)
    }

    func testPlaybackFinishClearsPlayingState() async {
        let player = StubAudioNotePlayer()
        let model = NotePlaybackModel(
            noteID: noteID, audioFileName: "rec.m4a",
            resolver: StubResolver(url: URL(fileURLWithPath: "/tmp/rec.m4a")), player: player
        )
        model.toggle()
        await model.settle()
        XCTAssertTrue(model.isPlaying)

        // The player reaching the end (onFinish) resets the button.
        player.finish()
        XCTAssertFalse(model.isPlaying)
    }

    func testPlayFailureLeavesNotPlaying() async {
        let player = StubAudioNotePlayer()
        player.playSucceeds = false
        let model = NotePlaybackModel(
            noteID: noteID, audioFileName: "rec.m4a",
            resolver: StubResolver(url: URL(fileURLWithPath: "/tmp/rec.m4a")), player: player
        )
        model.toggle()
        await model.settle()
        // An unplayable file leaves the model idle rather than stuck "playing".
        XCTAssertFalse(model.isPlaying)
    }

    /// When the note claims audio but the file is gone (resolver returns nil - swept or not synced),
    /// the play attempt resolves to nothing and leaves the model idle. Confirms the CarPlay-style
    /// re-validation: a file that vanished between navigation and play is not played as a stale URL.
    /// The model is a projection over a shared controller: when the controller moves on to ANOTHER
    /// note (as CarPlay might), this model reads as not playing rather than falsely showing Stop.
    func testModelReadsNotPlayingWhenControllerLoadsAnotherNote() async {
        let player = StubAudioNotePlayer()
        let controller = NotePlaybackController(
            resolver: StubResolver(url: URL(fileURLWithPath: "/tmp/rec.m4a")), player: player
        )
        let mine = Note(
            id: noteID, title: "mine", paragraphs: ["p"], createdAt: Date(),
            audioFileName: "mine.m4a", timings: [ParagraphTiming(start: 0, duration: 3)]
        )
        let other = Note(
            title: "other", paragraphs: ["p"], createdAt: Date(),
            audioFileName: "other.m4a", timings: [ParagraphTiming(start: 0, duration: 3)]
        )
        let model = NotePlaybackModel(note: mine, controller: controller)

        model.toggle()
        await model.settle()
        XCTAssertTrue(model.isPlaying, "playing my note shows Stop")

        // Another surface drives the shared controller to a different note.
        controller.play(note: other)
        await model.settle()
        XCTAssertFalse(model.isPlaying, "the model no longer claims playback once another note loads")
    }

    func testMissingFileAtPlayTimeLeavesNotPlaying() async {
        let player = StubAudioNotePlayer()
        let resolver = StubResolver(url: nil)
        let model = NotePlaybackModel(
            noteID: noteID, audioFileName: "rec.m4a", resolver: resolver, player: player
        )
        XCTAssertTrue(model.canPlay, "the note claims audio, so the affordance shows")

        model.toggle()
        await model.settle()

        XCTAssertEqual(resolver.resolveCount, 1)
        XCTAssertTrue(player.plays.isEmpty, "a missing file is never handed to the player")
        XCTAssertFalse(model.isPlaying)
    }
}

private extension NotePlaybackModel {
    /// Let the lazy resolve+play task complete before asserting. The resolver runs on a detached
    /// task; yielding a few times lets it hop back to the main actor and start playback.
    func settle() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }
}

/// Resolves to a fixed URL (or nil), counting calls so a test can pin lazy, at-play-time resolution.
private final class StubResolver: AudioURLResolving, @unchecked Sendable {
    private let url: URL?
    private let lock = NSLock()
    private var _resolveCount = 0
    var resolveCount: Int { lock.lock(); defer { lock.unlock() }; return _resolveCount }

    init(url: URL?) { self.url = url }

    func resolveAudioURL(for noteID: UUID, audioFileName: String?) -> URL? {
        lock.lock(); _resolveCount += 1; lock.unlock()
        return url
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

    func pause() {}
    func resume() -> Bool { true }
    func stop() { stopCount += 1 }
    var currentTime: Double { 0 }
    func seek(to time: Double) {}
    func finish() { onFinish?() }
}
