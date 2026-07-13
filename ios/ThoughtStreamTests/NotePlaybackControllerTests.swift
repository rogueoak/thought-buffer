import XCTest
@testable import ThoughtStream

/// The shared headless playback controller (spec 0008): the one audio path that both the phone
/// detail view and CarPlay drive. Proven with a stubbed player, a Now Playing spy, and a remote-
/// command spy, so play / pause / resume / stop / skip, the `MPNowPlayingInfoCenter` population, and
/// the remote-command handlers calling back into the controller are all provable without real audio.
@MainActor
final class NotePlaybackControllerTests: XCTestCase {

    private func recordedNote(title: String = "Morning drive", length: Double = 12) -> Note {
        Note(
            id: UUID(),
            title: title,
            paragraphs: ["One.", "Two."],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            audioFileName: "rec.m4a",
            timings: [
                ParagraphTiming(start: 0, duration: length / 2),
                ParagraphTiming(start: length / 2, duration: length / 2),
            ]
        )
    }

    private func makeController(
        url: URL? = URL(fileURLWithPath: "/tmp/rec.m4a"),
        player: SpyPlayer? = nil,
        nowPlaying: SpyNowPlaying? = nil,
        remote: SpyRemote? = nil
    ) -> NotePlaybackController {
        NotePlaybackController(
            resolver: StubResolver(url: url),
            player: player ?? SpyPlayer(),
            nowPlaying: nowPlaying ?? SpyNowPlaying(),
            remote: remote ?? SpyRemote(),
            skipInterval: 15
        )
    }

    func testPlayResolvesAndStartsFromTheTop() async {
        let player = SpyPlayer()
        let controller = makeController(player: player)
        let note = recordedNote()

        controller.play(note: note)
        await settle()

        XCTAssertEqual(player.plays.count, 1)
        XCTAssertEqual(player.plays.first?.start, 0)
        XCTAssertNil(player.plays.first?.duration, "the whole recording plays, not a range")
        XCTAssertTrue(controller.isPlaying)
        XCTAssertTrue(controller.isLoaded(note))
    }

    func testPlayPopulatesNowPlayingWithTitleAndDuration() async {
        let nowPlaying = SpyNowPlaying()
        let controller = makeController(nowPlaying: nowPlaying)
        let note = recordedNote(title: "Groceries", length: 20)

        controller.play(note: note)
        await settle()

        let info = nowPlaying.last ?? nil
        XCTAssertEqual(info?.title, "Groceries")
        XCTAssertEqual(info?.duration, 20)
        XCTAssertEqual(info?.rate, 1, "playing -> rate 1")
    }

    func testPlayEnablesRemoteCommands() async {
        let remote = SpyRemote()
        let controller = makeController(remote: remote)

        controller.play(note: recordedNote())
        await settle()

        XCTAssertTrue(remote.isRegistered, "playing wires the remote transport commands")
    }

    func testPauseAndResume() async {
        let player = SpyPlayer()
        let nowPlaying = SpyNowPlaying()
        let controller = makeController(player: player, nowPlaying: nowPlaying)
        controller.play(note: recordedNote())
        await settle()

        controller.pause()
        XCTAssertFalse(controller.isPlaying)
        XCTAssertTrue(controller.isPaused)
        XCTAssertEqual(player.pauseCount, 1)
        XCTAssertEqual(nowPlaying.last??.rate, 0, "paused -> Now Playing rate 0")

        controller.resume()
        XCTAssertTrue(controller.isPlaying)
        XCTAssertFalse(controller.isPaused)
        XCTAssertEqual(player.resumeCount, 1)
        XCTAssertEqual(nowPlaying.last??.rate, 1, "resumed -> rate 1")
    }

    func testStopClearsNowPlayingAndRemote() async {
        let nowPlaying = SpyNowPlaying()
        let remote = SpyRemote()
        let controller = makeController(nowPlaying: nowPlaying, remote: remote)
        controller.play(note: recordedNote())
        await settle()

        controller.stop()

        XCTAssertFalse(controller.isPlaying)
        XCTAssertNil(controller.currentNote)
        XCTAssertNil(nowPlaying.last ?? nil, "stop clears the Now Playing item")
        XCTAssertFalse(remote.isRegistered, "stop drops the remote commands")
    }

    func testSkipSeeksRelativeToCurrentTime() async {
        let player = SpyPlayer()
        player.currentTimeValue = 30
        let controller = makeController(player: player)
        controller.play(note: recordedNote())
        await settle()

        controller.skip(by: 15)
        XCTAssertEqual(player.seeks.last, 45, "skip forward seeks currentTime + interval")

        player.currentTimeValue = 45
        controller.skip(by: -15)
        XCTAssertEqual(player.seeks.last, 30, "skip back seeks currentTime - interval")
    }

    func testRemoteTogglePauseCommandCallsController() async {
        let player = SpyPlayer()
        let remote = SpyRemote()
        let controller = makeController(player: player, remote: remote)
        controller.play(note: recordedNote())
        await settle()
        XCTAssertTrue(controller.isPlaying)

        // The lock-screen / CarPlay toggle button fires the registered handler; it must pause the
        // shared controller (the same code the in-app button drives).
        remote.fireToggle()
        XCTAssertTrue(controller.isPaused)
        XCTAssertEqual(player.pauseCount, 1)

        remote.fireToggle()
        XCTAssertTrue(controller.isPlaying)
    }

    func testRemoteSkipCommandsCallController() async {
        let player = SpyPlayer()
        player.currentTimeValue = 60
        let remote = SpyRemote()
        let controller = makeController(player: player, remote: remote)
        controller.play(note: recordedNote())
        await settle()

        remote.fireSkipForward()
        XCTAssertEqual(player.seeks.last, 75)
        remote.fireStop()
        XCTAssertNil(controller.currentNote, "the remote stop command stops the controller")
    }

    func testPlayingASecondNoteReplacesTheFirst() async {
        let player = SpyPlayer()
        let controller = makeController(player: player)
        let first = recordedNote(title: "first")
        let second = recordedNote(title: "second")

        controller.play(note: first)
        await settle()
        controller.play(note: second)
        await settle()

        XCTAssertTrue(controller.isLoaded(second))
        XCTAssertFalse(controller.isLoaded(first))
        XCTAssertEqual(player.plays.count, 2)
    }

    func testPlayNoteWithoutAudioIsNoOp() async {
        let player = SpyPlayer()
        let controller = makeController(player: player)
        let textOnly = Note(title: "text", paragraphs: ["x"], createdAt: Date())

        controller.play(note: textOnly)
        await settle()

        XCTAssertTrue(player.plays.isEmpty)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertNil(controller.currentNote)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

// MARK: - Test doubles

private final class StubResolver: AudioURLResolving, @unchecked Sendable {
    let url: URL?
    init(url: URL?) { self.url = url }
    func resolveAudioURL(for noteID: UUID, audioFileName: String?) -> URL? { url }
}

@MainActor
private final class SpyPlayer: AudioNotePlayer {
    var onFinish: (() -> Void)?
    var playSucceeds = true
    var currentTimeValue: Double = 0
    private(set) var plays: [(url: URL, start: Double, duration: Double?)] = []
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var stopCount = 0
    private(set) var seeks: [Double] = []

    @discardableResult
    func play(url: URL, from start: Double, duration: Double?) -> Bool {
        plays.append((url, start, duration))
        return playSucceeds
    }
    func pause() { pauseCount += 1 }
    func resume() -> Bool { resumeCount += 1; return true }
    func stop() { stopCount += 1 }
    var currentTime: Double { currentTimeValue }
    func seek(to time: Double) { seeks.append(time) }
    func finish() { onFinish?() }
}

@MainActor
private final class SpyNowPlaying: NowPlayingInfoWriting {
    /// The updates published, so a test can read the latest (an outer nil means "cleared").
    private(set) var updates: [NowPlayingInfo?] = []
    var last: NowPlayingInfo?? { updates.last }
    func update(_ info: NowPlayingInfo?) { updates.append(info) }
}

@MainActor
private final class SpyRemote: RemoteCommandRegistering {
    private(set) var isRegistered = false
    private var play: (() -> Void)?
    private var pause: (() -> Void)?
    private var toggle: (() -> Void)?
    private var stop: (() -> Void)?
    private var skipForward: (() -> Void)?
    private var skipBackward: (() -> Void)?

    func register(
        play: @escaping () -> Void,
        pause: @escaping () -> Void,
        toggle: @escaping () -> Void,
        stop: @escaping () -> Void,
        skipForward: @escaping () -> Void,
        skipBackward: @escaping () -> Void
    ) {
        isRegistered = true
        self.play = play; self.pause = pause; self.toggle = toggle
        self.stop = stop; self.skipForward = skipForward; self.skipBackward = skipBackward
    }

    func unregisterAll() {
        isRegistered = false
        play = nil; pause = nil; toggle = nil; stop = nil; skipForward = nil; skipBackward = nil
    }

    func fireToggle() { toggle?() }
    func fireStop() { stop?() }
    func fireSkipForward() { skipForward?() }
    func fireSkipBackward() { skipBackward?() }
}
