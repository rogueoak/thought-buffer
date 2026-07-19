import XCTest
@testable import ThoughtStream

/// The shared headless playback controller (spec 0008): the one audio path that both the phone
/// detail view and CarPlay drive. Proven with a stubbed player, a Now Playing spy, and a remote-
/// command spy, so play / pause / resume / stop / skip, the `MPNowPlayingInfoCenter` population, and
/// the remote-command handlers calling back into the controller are all provable without real audio.
@MainActor
final class ThoughtPlaybackControllerTests: XCTestCase {

    private func recordedThought(title: String = "Morning drive", length: Double = 12) -> Thought {
        Thought(
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

    /// The resolver behind the controller built by `makeController`, retained so a test can wait on
    /// its `resolveCount` - resolution always runs (whether the play then succeeds or is a no-op /
    /// failure), so it is the universal condition for "the lazy off-main resolve+play has run".
    private var lastResolver: StubResolver!

    private func makeController(
        url: URL? = URL(fileURLWithPath: "/tmp/rec.m4a"),
        player: SpyPlayer? = nil,
        nowPlaying: SpyNowPlaying? = nil,
        remote: SpyRemote? = nil,
        lockScreenTitle: @escaping () -> LockScreenTitle = { .default }
    ) -> ThoughtPlaybackController {
        let resolver = StubResolver(url: url)
        lastResolver = resolver
        return ThoughtPlaybackController(
            resolver: resolver,
            player: player ?? SpyPlayer(),
            nowPlaying: nowPlaying ?? SpyNowPlaying(),
            remote: remote ?? SpyRemote(),
            lockScreenTitle: lockScreenTitle,
            skipInterval: 15
        )
    }

    func testPlayResolvesAndStartsFromTheTop() async {
        let player = SpyPlayer()
        let controller = makeController(player: player)
        let thought = recordedThought()

        controller.play(thought: thought)
        await settle()

        XCTAssertEqual(player.plays.count, 1)
        XCTAssertEqual(player.plays.first?.start, 0)
        XCTAssertNil(player.plays.first?.duration, "the whole recording plays, not a range")
        XCTAssertTrue(controller.isPlaying)
        XCTAssertTrue(controller.isLoaded(thought))
    }

    func testPlayPopulatesNowPlayingWithTitleAndDuration() async {
        let nowPlaying = SpyNowPlaying()
        let controller = makeController(nowPlaying: nowPlaying)
        let thought = recordedThought(title: "Groceries", length: 20)

        controller.play(thought: thought)
        await settle()

        let info = nowPlaying.last ?? nil
        XCTAssertEqual(info?.title, "Groceries")
        XCTAssertEqual(info?.duration, 20)
        XCTAssertEqual(info?.rate, 1, "playing -> rate 1")
    }

    func testPlayEnablesRemoteCommands() async {
        let remote = SpyRemote()
        let controller = makeController(remote: remote)

        controller.play(thought: recordedThought())
        await settle()

        XCTAssertTrue(remote.isRegistered, "playing wires the remote transport commands")
    }

    func testPauseAndResume() async {
        let player = SpyPlayer()
        let nowPlaying = SpyNowPlaying()
        let controller = makeController(player: player, nowPlaying: nowPlaying)
        controller.play(thought: recordedThought())
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
        controller.play(thought: recordedThought())
        await settle()

        controller.stop()

        XCTAssertFalse(controller.isPlaying)
        XCTAssertNil(controller.currentThought)
        XCTAssertNil(nowPlaying.last ?? nil, "stop clears the Now Playing item")
        XCTAssertFalse(remote.isRegistered, "stop drops the remote commands")
    }

    func testSkipSeeksRelativeToCurrentTime() async {
        let player = SpyPlayer()
        player.currentTimeValue = 30
        let controller = makeController(player: player)
        // A recording long enough that the relative skip stays in range (spec 0027: skip clamps to the
        // recording's duration, so a short fixture would clamp the +/- math being asserted here).
        controller.play(thought: recordedThought(length: 120))
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
        controller.play(thought: recordedThought())
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
        controller.play(thought: recordedThought(length: 120))
        await settle()

        remote.fireSkipForward()
        XCTAssertEqual(player.seeks.last, 75)
        remote.fireStop()
        XCTAssertNil(controller.currentThought, "the remote stop command stops the controller")
    }

    /// The remote PLAY command (lock screen / CarPlay play button) must resume the paused controller,
    /// not restart it. Fired individually so the play handler's routing is proven on its own.
    func testRemotePlayCommandResumesController() async {
        let player = SpyPlayer()
        let remote = SpyRemote()
        let controller = makeController(player: player, remote: remote)
        controller.play(thought: recordedThought())
        await settle()
        controller.pause()
        XCTAssertTrue(controller.isPaused)

        remote.firePlay()
        XCTAssertTrue(controller.isPlaying, "the remote play command resumes playback")
        XCTAssertEqual(player.resumeCount, 1, "play resumes rather than restarting from the top")
        XCTAssertEqual(player.plays.count, 1, "no new play was started")
    }

    /// The remote PAUSE command (lock screen / CarPlay pause button) must pause the controller. Fired
    /// individually so the pause handler's routing is proven on its own.
    func testRemotePauseCommandPausesController() async {
        let player = SpyPlayer()
        let remote = SpyRemote()
        let controller = makeController(player: player, remote: remote)
        controller.play(thought: recordedThought())
        await settle()
        XCTAssertTrue(controller.isPlaying)

        remote.firePause()
        XCTAssertTrue(controller.isPaused, "the remote pause command pauses playback")
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(player.pauseCount, 1)
    }

    /// The remote SKIP-BACKWARD command must seek back by the interval. Fired individually so the
    /// skip-back handler's routing is proven on its own (the forward case is covered above).
    func testRemoteSkipBackwardCommandCallsController() async {
        let player = SpyPlayer()
        player.currentTimeValue = 60
        let remote = SpyRemote()
        let controller = makeController(player: player, remote: remote)
        controller.play(thought: recordedThought(length: 120))
        await settle()

        remote.fireSkipBackward()
        XCTAssertEqual(player.seeks.last, 45, "skip back seeks currentTime - interval")
    }

    /// Two observers on ONE shared controller (the phone projection and the CarPlay scene) must BOTH
    /// be notified on a transport change - the multicast that closed the one-way-door race where a
    /// single-slot callback let one surface clobber the other's.
    func testMultipleTransportObserversAllReceiveUpdates() async {
        let controller = makeController()
        var firstCount = 0
        var secondCount = 0
        controller.addTransportObserver { firstCount += 1 }
        controller.addTransportObserver { secondCount += 1 }

        controller.play(thought: recordedThought())
        await settle()
        controller.pause()

        XCTAssertGreaterThan(firstCount, 0, "the first observer received transport updates")
        XCTAssertGreaterThan(secondCount, 0, "the second observer received transport updates")
        XCTAssertEqual(firstCount, secondCount, "both observers saw the same number of updates")
    }

    /// A removed observer stops receiving updates while the remaining one keeps getting them, so a
    /// surface disconnecting (CarPlay) does not silence the other (phone).
    func testRemovedTransportObserverStopsReceivingUpdates() async {
        let controller = makeController()
        var keptCount = 0
        var removedCount = 0
        controller.addTransportObserver { keptCount += 1 }
        let token = controller.addTransportObserver { removedCount += 1 }

        controller.play(thought: recordedThought())
        await settle()
        let removedAtRemoval = removedCount
        controller.removeTransportObserver(token)
        controller.pause()

        XCTAssertGreaterThan(keptCount, 0)
        XCTAssertEqual(removedCount, removedAtRemoval, "the removed observer got no further updates")
    }

    /// The lock-screen-title preference controls the published Now Playing title: `.noteTitle`
    /// publishes the thought's own title, `.generic` publishes the fixed generic label so a sensitive
    /// first line does not appear on the lock screen / Control Center / CarPlay.
    func testLockScreenTitlePublishesThoughtTitleByDefault() async {
        let nowPlaying = SpyNowPlaying()
        let controller = makeController(nowPlaying: nowPlaying, lockScreenTitle: { .noteTitle })
        controller.play(thought: recordedThought(title: "Sensitive line"))
        await settle()
        XCTAssertEqual(nowPlaying.last??.title, "Sensitive line")
    }

    func testGenericLockScreenTitlePublishesFixedLabel() async {
        let nowPlaying = SpyNowPlaying()
        let controller = makeController(nowPlaying: nowPlaying, lockScreenTitle: { .generic })
        controller.play(thought: recordedThought(title: "Sensitive line"))
        await settle()
        XCTAssertEqual(nowPlaying.last??.title, LockScreenTitle.genericTitle)
        XCTAssertNotEqual(nowPlaying.last??.title, "Sensitive line", "the thought title is not exposed")
    }

    func testPlayingASecondThoughtReplacesTheFirst() async {
        let player = SpyPlayer()
        let controller = makeController(player: player)
        let first = recordedThought(title: "first")
        let second = recordedThought(title: "second")

        controller.play(thought: first)
        await eventually { player.plays.count == 1 }
        controller.play(thought: second)
        await eventually { player.plays.count == 2 }

        XCTAssertTrue(controller.isLoaded(second))
        XCTAssertFalse(controller.isLoaded(first))
        XCTAssertEqual(player.plays.count, 2)
    }

    func testNaturalFinishClearsNowPlayingAndRemote() async {
        let player = SpyPlayer()
        let nowPlaying = SpyNowPlaying()
        let remote = SpyRemote()
        let controller = makeController(player: player, nowPlaying: nowPlaying, remote: remote)
        controller.play(thought: recordedThought())
        await settle()
        XCTAssertTrue(controller.isPlaying)

        // The recording reaches its end on its own (the player's onFinish fires).
        player.finish()

        XCTAssertFalse(controller.isPlaying)
        XCTAssertNil(controller.currentThought, "a natural finish clears the loaded thought")
        XCTAssertNil(nowPlaying.last ?? nil, "a natural finish clears Now Playing")
        XCTAssertFalse(remote.isRegistered, "a natural finish drops the remote commands")
    }

    func testSkipWhileIdleIsNoOp() {
        let player = SpyPlayer()
        let controller = makeController(player: player)
        // Nothing loaded: a stray remote skip must not seek.
        controller.skip(by: 15)
        XCTAssertTrue(player.seeks.isEmpty)
    }

    func testPlayThoughtWithoutAudioIsNoOp() async {
        let player = SpyPlayer()
        let controller = makeController(player: player)
        let textOnly = Thought(title: "text", paragraphs: ["x"], createdAt: Date())

        controller.play(thought: textOnly)
        await settle()

        XCTAssertTrue(player.plays.isEmpty)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertNil(controller.currentThought)
    }

    /// A no-audio thought must not tear down a recording that is already playing: the guard runs before
    /// any teardown, so the current thought stays loaded and its Now Playing / remote wiring intact.
    func testPlayThoughtWithoutAudioDoesNotDisruptCurrentPlayback() async {
        let nowPlaying = SpyNowPlaying()
        let remote = SpyRemote()
        let controller = makeController(nowPlaying: nowPlaying, remote: remote)
        let playing = recordedThought(title: "playing")
        controller.play(thought: playing)
        await settle()
        XCTAssertTrue(controller.isPlaying)

        controller.play(thought: Thought(title: "text", paragraphs: ["x"], createdAt: Date()))
        await settle()

        XCTAssertTrue(controller.isLoaded(playing), "the playing thought is untouched")
        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(nowPlaying.last??.title, "playing", "Now Playing still shows the real thought")
        XCTAssertTrue(remote.isRegistered, "remote commands stay wired to the playing thought")
    }

    /// A failed play (resolver returns nil - swept / not synced) must not strand the previous thought's
    /// Now Playing item or remote commands.
    func testFailedPlayClearsNowPlayingAndRemote() async {
        let nowPlaying = SpyNowPlaying()
        let remote = SpyRemote()
        let controller = makeController(url: nil, nowPlaying: nowPlaying, remote: remote)

        controller.play(thought: recordedThought())
        await settle()

        XCTAssertFalse(controller.isPlaying)
        XCTAssertNil(controller.currentThought)
        XCTAssertNil(nowPlaying.last ?? nil, "a failed play leaves no stale Now Playing item")
        XCTAssertFalse(remote.isRegistered, "a failed play leaves no stale remote wiring")
    }

    /// The production seek clamp lives in `SystemAudioThoughtPlayer` (`clampedSeekTime`, called by
    /// `seek(to:)`). Assert it directly with out-of-range values: a skip-forward past the end pins to
    /// the duration, a skip-back below 0 pins to 0. This FAILS if the clamp is removed - a raw
    /// pass-through would return the out-of-range value, not the clamped one. Asserted on the pure
    /// clamp rather than through a real `AVAudioPlayer` (whose own `currentTime` clamps and would mask
    /// a removed production clamp) or a non-clamping spy (which would bypass it).
    func testSystemPlayerSeekClampsToFileBounds() {
        let duration = 12.0
        // Past the end -> clamped to the duration, not the raw 999.
        XCTAssertEqual(SystemAudioThoughtPlayer.clampedSeekTime(999, duration: duration), duration)
        // Below zero -> clamped to 0, not the raw -50.
        XCTAssertEqual(SystemAudioThoughtPlayer.clampedSeekTime(-50, duration: duration), 0)
        // In range -> unchanged.
        XCTAssertEqual(SystemAudioThoughtPlayer.clampedSeekTime(5, duration: duration), 5)
        // Exactly at the boundaries -> unchanged (the on/off edge where an off-by-one would live).
        XCTAssertEqual(SystemAudioThoughtPlayer.clampedSeekTime(0, duration: duration), 0)
        XCTAssertEqual(SystemAudioThoughtPlayer.clampedSeekTime(duration, duration: duration), duration)
    }

    // MARK: - Transport progress + scrub (spec 0027)

    /// Playing publishes the recording's total duration and resets elapsed, so the bottom player's slider
    /// spans the full recording from the top.
    func testPlayPublishesDurationAndResetsElapsed() async {
        let controller = makeController()
        controller.play(thought: recordedThought(length: 24))
        await settle()

        XCTAssertEqual(controller.duration, 24, "duration comes from the thought's recording length")
        XCTAssertEqual(controller.elapsed, 0, "a fresh play starts elapsed at 0")
    }

    /// Seeking to an absolute position updates the published elapsed and seeks the player there, so the
    /// bar's slider and the player agree after a drag.
    func testSeekUpdatesElapsedAndSeeksPlayer() async {
        let player = SpyPlayer()
        let controller = makeController(player: player)
        controller.play(thought: recordedThought(length: 30))
        await settle()

        controller.seek(to: 12)
        XCTAssertEqual(player.seeks.last, 12, "the player is sought to the absolute target")
        XCTAssertEqual(controller.elapsed, 12, "elapsed reflects the new position immediately")
    }

    /// A seek past either end clamps into `[0, duration]` (the same rule the player applies), so a drag
    /// to the far edge or a scrub past the end lands in range rather than out of bounds.
    func testSeekClampsToDuration() async {
        let player = SpyPlayer()
        let controller = makeController(player: player)
        controller.play(thought: recordedThought(length: 20))
        await settle()

        controller.seek(to: 999)
        XCTAssertEqual(controller.elapsed, 20, "a seek past the end pins to the duration")
        controller.seek(to: -5)
        XCTAssertEqual(controller.elapsed, 0, "a seek before the start pins to 0")
    }

    /// The feedback-0027 regression guard, at the model level: after a seek WHILE PLAYING, the live-progress
    /// ticker must RESUME advancing `elapsed` from the sought position - not freeze at it, and not restart at
    /// 0. Reproduces "progress stops moving after scrubbing" purely (no real audio): seek to 12, then let the
    /// player advance past it and assert the ticker samples the new positions into `elapsed`. A ticker that
    /// stopped on seek (the bug) would leave `elapsed` pinned at 12.
    func testElapsedResumesFromSoughtPositionWhilePlaying() async {
        let player = SpyPlayer()
        let controller = makeController(player: player)
        controller.play(thought: recordedThought(length: 60))
        await settle()

        // The user scrubs to 12s (as the bottom player commits on drag-end).
        player.currentTimeValue = 12
        controller.seek(to: 12)
        XCTAssertEqual(controller.elapsed, 12, "the seek lands elapsed at the sought position")

        // Playback continues past the sought point; the ticker (still running - a seek does not stop it)
        // must pick the advancing position up into elapsed, so the bar keeps moving after the scrub.
        player.currentTimeValue = 13
        await eventually({ controller.elapsed == 13 }, tries: 100)
        XCTAssertEqual(controller.elapsed, 13, "elapsed advances past the sought position, not frozen at it")

        player.currentTimeValue = 14
        await eventually({ controller.elapsed == 14 }, tries: 100)
        XCTAssertEqual(controller.elapsed, 14, "progress keeps advancing on the next tick")
    }

    /// A skip forward past the end clamps to the duration rather than seeking out of range.
    func testSkipForwardClampsToDuration() async {
        let player = SpyPlayer()
        player.currentTimeValue = 18
        let controller = makeController(player: player)
        controller.play(thought: recordedThought(length: 20))
        await settle()

        controller.skip(by: 15)
        XCTAssertEqual(controller.elapsed, 20, "skip forward past the end clamps to the duration")
    }

    /// The system UI's scrubber (lock screen / Control Center / Dynamic Island) fires the registered
    /// change-position handler with an absolute target; it must seek the shared controller there.
    func testRemoteScrubCommandSeeksController() async {
        let player = SpyPlayer()
        let remote = SpyRemote()
        let controller = makeController(player: player, remote: remote)
        controller.play(thought: recordedThought(length: 40))
        await settle()

        remote.fireScrub(to: 25)
        XCTAssertEqual(player.seeks.last, 25, "the scrubber seeks the recording to the dragged position")
        XCTAssertEqual(controller.elapsed, 25)
    }

    /// The live-progress ticker samples the player's position into `elapsed` while playing, and stops the
    /// moment playback is paused - so the bar advances during playback and freezes on pause. Polled with a
    /// generous try budget since a tick is ~250ms (longer than the default `eventually` window).
    func testProgressTickerSamplesElapsedWhilePlayingAndStopsOnPause() async {
        let player = SpyPlayer()
        let controller = makeController(player: player)
        controller.play(thought: recordedThought(length: 120))
        await settle()

        // The player advances; the ticker must pick the new position up into the published elapsed.
        player.currentTimeValue = 7
        await eventually({ controller.elapsed == 7 }, tries: 100)
        XCTAssertEqual(controller.elapsed, 7, "the ticker samples player.currentTime into elapsed while playing")

        // Pause stops the ticker: a later player advance must NOT move the published elapsed.
        controller.pause()
        player.currentTimeValue = 42
        // Give any lingering ticker a few 250ms intervals to (wrongly) fire; elapsed must stay put.
        for _ in 0..<4 { await Task.yield(); try? await Task.sleep(nanoseconds: 300_000_000) }
        XCTAssertEqual(controller.elapsed, 7, "a paused ticker does not keep sampling the player")
    }

    /// A natural end-of-track fills the bar before teardown: the Now Playing item's elapsed is pinned to
    /// the full duration on finish (the ticker stops a sample short), so a played-to-completion recording
    /// shows a completed progress bar on the lock screen / Dynamic Island rather than one frozen just shy
    /// of the end. (The in-app `elapsed` then resets as the controller tears down and the bar hides.)
    func testNaturalFinishFillsNowPlayingElapsedToDuration() async {
        let player = SpyPlayer()
        let nowPlaying = SpyNowPlaying()
        let controller = makeController(player: player, nowPlaying: nowPlaying)
        controller.play(thought: recordedThought(length: 30))
        await settle()

        // The player ends a sample short of the full length, then finishes on its own.
        player.currentTimeValue = 29
        player.finish()

        // The LAST non-nil Now Playing update before the clear pinned elapsed to the full duration.
        let filled = nowPlaying.updates.compactMap { $0 }.last
        XCTAssertEqual(filled?.elapsed, 30, "the finish fills the Now Playing bar to the full duration")
        XCTAssertNil(nowPlaying.last ?? nil, "the item is then cleared as playback tears down")
    }

    /// Stopping clears the published progress so the bar (were it to briefly linger) shows no stale
    /// elapsed/duration.
    func testStopClearsProgress() async {
        let controller = makeController()
        controller.play(thought: recordedThought(length: 30))
        await settle()
        controller.seek(to: 10)
        XCTAssertEqual(controller.elapsed, 10)

        controller.stop()
        XCTAssertEqual(controller.elapsed, 0, "stop clears elapsed")
        XCTAssertEqual(controller.duration, 0, "stop clears duration")
    }

    // MARK: - Queue (spec 0015)

    func testPlayQueueFiltersToRecordingsAndPlaysFirst() async {
        let player = SpyPlayer()
        let controller = makeController(player: player)
        let first = recordedThought(title: "first")
        let textOnly = Thought(title: "text", paragraphs: ["x"], createdAt: Date())
        let second = recordedThought(title: "second")

        // The text-only thought is skipped; the first RECORDED thought plays.
        controller.playQueue([first, textOnly, second])
        await eventually { player.plays.count == 1 }

        XCTAssertEqual(player.plays.count, 1, "exactly the first recorded thought started")
        XCTAssertTrue(controller.isLoaded(first))
        XCTAssertTrue(controller.hasNext, "a next recorded entry exists")
    }

    func testEmptyOrNoRecordingQueueIsNoOp() async {
        let player = SpyPlayer()
        let controller = makeController(player: player)

        controller.playQueue([])
        controller.playQueue([Thought(title: "text", paragraphs: ["x"], createdAt: Date())])
        await settle()

        XCTAssertTrue(player.plays.isEmpty, "no recorded thought -> nothing plays")
        XCTAssertFalse(controller.isPlaying)
        XCTAssertNil(controller.currentThought)
        XCTAssertFalse(controller.hasNext)
    }

    func testNoRecordingQueueDoesNotDisruptCurrentPlayback() async {
        let player = SpyPlayer()
        let controller = makeController(player: player)
        let playing = recordedThought(title: "playing")
        controller.play(thought: playing)
        await eventually { player.plays.count == 1 }

        // An all-text queue must not tear down what is already playing (the no-op guard runs first).
        controller.playQueue([Thought(title: "text", paragraphs: ["x"], createdAt: Date())])
        await settle()

        XCTAssertTrue(controller.isLoaded(playing), "the playing thought is untouched")
        XCTAssertEqual(player.plays.count, 1)
    }

    func testQueueAutoAdvancesOnNaturalFinish() async {
        let player = SpyPlayer()
        let controller = makeController(player: player)
        let first = recordedThought(title: "first")
        let second = recordedThought(title: "second")

        controller.playQueue([first, second])
        await eventually { player.plays.count == 1 }
        XCTAssertTrue(controller.isLoaded(first))
        XCTAssertTrue(controller.hasNext)

        // The first recording ends on its own -> the queue advances to the second.
        player.finish()
        await eventually { player.plays.count == 2 }

        XCTAssertTrue(controller.isLoaded(second), "a natural finish advances to the next queued thought")
        XCTAssertFalse(controller.hasNext, "the second is the last -> no next")
    }

    func testQueueSkipsAnUnplayableRecordingAndAdvances() async {
        let player = SpyPlayer()
        let controller = makeController(player: player)
        let first = recordedThought(title: "first")
        let missing = recordedThought(title: "missing")
        let third = recordedThought(title: "third")
        // The middle recording cannot be resolved (a vanished / unreadable file).
        lastResolver?.setNilForIDs([missing.id])

        controller.playQueue([first, missing, third])
        await eventually { player.plays.count == 1 }
        XCTAssertTrue(controller.isLoaded(first))

        // First ends -> advance to `missing`, which resolves nil and cannot play -> the queue must SKIP
        // it to `third` rather than stranding (populated queue, nothing playing).
        player.finish()
        await eventually { player.plays.count == 2 }
        XCTAssertTrue(controller.isLoaded(third), "an unplayable mid-queue recording is skipped, not stranded")
        XCTAssertFalse(controller.hasNext)
    }

    func testQueueSurvivesPauseAndResumeThenAdvances() async {
        let player = SpyPlayer()
        let controller = makeController(player: player)
        let first = recordedThought(title: "first")
        let second = recordedThought(title: "second")

        controller.playQueue([first, second])
        await eventually { player.plays.count == 1 }
        controller.pause()
        XCTAssertTrue(controller.hasNext, "pause does not disturb the queue")
        controller.resume()

        // A natural finish after a pause/resume cycle still advances the queue (index intact).
        player.finish()
        await eventually { player.plays.count == 2 }
        XCTAssertTrue(controller.isLoaded(second))
    }

    func testQueueClearsAfterLastNaturalFinish() async {
        let player = SpyPlayer()
        let nowPlaying = SpyNowPlaying()
        let remote = SpyRemote()
        let controller = makeController(player: player, nowPlaying: nowPlaying, remote: remote)
        let first = recordedThought(title: "first")
        let second = recordedThought(title: "second")

        controller.playQueue([first, second])
        await eventually { player.plays.count == 1 }
        player.finish()
        await eventually { player.plays.count == 2 }

        // The last queued recording ends -> everything clears (no advance, no stale wiring).
        player.finish()

        XCTAssertFalse(controller.isPlaying)
        XCTAssertNil(controller.currentThought, "the queue is exhausted -> nothing loaded")
        XCTAssertFalse(controller.hasNext)
        XCTAssertNil(nowPlaying.last ?? nil, "the end of the queue clears Now Playing")
        XCTAssertFalse(remote.isRegistered, "the end of the queue drops the remote commands")
    }

    func testPlayNextSkipsToNextQueuedThought() async {
        let player = SpyPlayer()
        let controller = makeController(player: player)
        let first = recordedThought(title: "first")
        let second = recordedThought(title: "second")

        controller.playQueue([first, second])
        await eventually { player.plays.count == 1 }

        // The user taps Next -> skip straight to the second without waiting for a natural finish.
        controller.playNext()
        await eventually { player.plays.count == 2 }

        XCTAssertTrue(controller.isLoaded(second))
        XCTAssertFalse(controller.hasNext, "the second is the last")
    }

    func testPlayNextOnLastEntryStops() async {
        let player = SpyPlayer()
        let controller = makeController(player: player)
        let only = recordedThought(title: "only")

        controller.playQueue([only])
        await eventually { player.plays.count == 1 }
        XCTAssertFalse(controller.hasNext, "a single-entry queue has no next")

        // Next on the last (here, only) entry stops.
        controller.playNext()

        XCTAssertFalse(controller.isPlaying)
        XCTAssertNil(controller.currentThought, "Next past the end stops")
    }

    func testStopClearsTheQueue() async {
        let player = SpyPlayer()
        let controller = makeController(player: player)
        let first = recordedThought(title: "first")
        let second = recordedThought(title: "second")

        controller.playQueue([first, second])
        await eventually { player.plays.count == 1 }
        XCTAssertTrue(controller.hasNext)

        controller.stop()
        XCTAssertNil(controller.currentThought)
        XCTAssertFalse(controller.hasNext, "stop clears the queue")

        // A natural finish AFTER a stop must not resurrect an orphaned queue.
        player.finish()
        XCTAssertEqual(player.plays.count, 1, "no queued thought plays after a stop")
    }

    func testDirectPlayClearsAPriorQueue() async {
        let player = SpyPlayer()
        let controller = makeController(player: player)
        let queued1 = recordedThought(title: "q1")
        let queued2 = recordedThought(title: "q2")
        let single = recordedThought(title: "single")

        controller.playQueue([queued1, queued2])
        await eventually { player.plays.count == 1 }
        XCTAssertTrue(controller.hasNext)

        // A direct single-thought play ends the queue -> a later finish does not advance the old queue.
        controller.play(thought: single)
        await eventually { player.plays.count == 2 }
        XCTAssertFalse(controller.hasNext, "a direct play clears the queue")

        player.finish()
        XCTAssertEqual(player.plays.count, 2, "no orphaned queue advance after a direct play")
        XCTAssertNil(controller.currentThought)
    }

    func testQueueUsesOneNowPlayingWriterAcrossAdvance() async {
        let player = SpyPlayer()
        let nowPlaying = SpyNowPlaying()
        let controller = makeController(player: player, nowPlaying: nowPlaying)
        let first = recordedThought(title: "first")
        let second = recordedThought(title: "second")

        controller.playQueue([first, second])
        await eventually { player.plays.count == 1 }
        XCTAssertEqual(nowPlaying.last??.title, "first", "the first queued thought is the Now Playing item")

        player.finish()
        await eventually { player.plays.count == 2 }

        // The advance goes through the ONE Now Playing writer: the item is now the second thought, never a
        // second concurrent item. (A double writer would leave the first title stranded.)
        XCTAssertEqual(nowPlaying.last??.title, "second", "the advance retitles the SAME Now Playing item")
    }

    /// A single-thought `play(thought:)` must not populate the queue (spec 0015): no next item, so the bar
    /// shows no Next button, and a natural finish clears rather than advancing.
    func testSinglePlayLeavesNoQueue() async {
        let player = SpyPlayer()
        let controller = makeController(player: player)

        controller.play(thought: recordedThought())
        await eventually { player.plays.count == 1 }

        XCTAssertFalse(controller.hasNext, "a single play has no queue and no next")
        player.finish()
        XCTAssertEqual(player.plays.count, 1, "a single play's finish does not advance a queue")
        XCTAssertNil(controller.currentThought)
    }

    /// Poll `condition` until it holds (or the tries run out), yielding AND sleeping a touch between
    /// tries so the lazy off-main resolve+play's detached hop back to the main actor is not raced
    /// under full-suite load. Condition-based rather than a fixed sleep, so a test waits exactly as
    /// long as it needs and no longer - the `eventually(_:)` pattern used elsewhere in the suite.
    private func eventually(_ condition: () -> Bool, tries: Int = 50) async {
        for _ in 0..<tries {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Wait for the lazy resolve+play to have run: resolution always happens (even for a no-op or a
    /// failed play), so `resolveCount` is the universal "the play attempt has settled" signal.
    private func settle() async {
        await eventually { self.lastResolver?.resolveCount ?? 0 >= 1 }
    }
}

// MARK: - Test doubles

private final class StubResolver: AudioURLResolving, @unchecked Sendable {
    let url: URL?
    private let lock = NSLock()
    private var _resolveCount = 0
    /// How many times `resolveAudioURL` has been called, so a test can wait on the lazy off-main
    /// resolve having run (thread-safe: resolution runs on a detached task).
    var resolveCount: Int { lock.lock(); defer { lock.unlock() }; return _resolveCount }

    /// Thought ids that resolve to nil (a missing / unresolvable recording), so a test can make one entry
    /// of a queue fail to play and assert the queue skips it.
    private var _nilForIDs: Set<UUID> = []
    func setNilForIDs(_ ids: Set<UUID>) { lock.lock(); _nilForIDs = ids; lock.unlock() }

    init(url: URL?) { self.url = url }

    func resolveAudioURL(for thoughtID: UUID, audioFileName: String?) -> URL? {
        lock.lock(); _resolveCount += 1; let fails = _nilForIDs.contains(thoughtID); lock.unlock()
        return fails ? nil : url
    }
}

@MainActor
private final class SpyPlayer: AudioThoughtPlayer {
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
    private var scrub: ((Double) -> Void)?

    func register(
        play: @escaping () -> Void,
        pause: @escaping () -> Void,
        toggle: @escaping () -> Void,
        stop: @escaping () -> Void,
        skipForward: @escaping () -> Void,
        skipBackward: @escaping () -> Void,
        scrub: @escaping (Double) -> Void
    ) {
        isRegistered = true
        self.play = play; self.pause = pause; self.toggle = toggle
        self.stop = stop; self.skipForward = skipForward; self.skipBackward = skipBackward
        self.scrub = scrub
    }

    func unregisterAll() {
        isRegistered = false
        play = nil; pause = nil; toggle = nil; stop = nil; skipForward = nil; skipBackward = nil
        scrub = nil
    }

    func firePlay() { play?() }
    func firePause() { pause?() }
    func fireToggle() { toggle?() }
    func fireStop() { stop?() }
    func fireSkipForward() { skipForward?() }
    func fireSkipBackward() { skipBackward?() }
    func fireScrub(to position: Double) { scrub?(position) }
}
