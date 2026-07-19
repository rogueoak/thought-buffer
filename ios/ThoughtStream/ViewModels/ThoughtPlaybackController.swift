import Foundation

/// The one headless audio playback path for a saved thought's recording (spec 0008).
///
/// Both the phone detail view (through `ThoughtPlaybackModel`) and the CarPlay scene drive THIS type, so
/// there is exactly one place that talks to the `AudioThoughtPlayer` and one writer of
/// `MPNowPlayingInfoCenter`. It owns:
///
/// - lazy, off-main URL resolution via `AudioURLResolving` (a recording can be swept or synced away
///   between navigation and play, and the iCloud presence check can block, so it is resolved at play
///   time on a detached task, exactly as spec 0007's model did);
/// - play / pause / resume / stop / relative-skip over the whole recording via `AudioThoughtPlayer`;
/// - the system Now Playing metadata (`NowPlayingInfoWriting`) and remote transport commands
///   (`RemoteCommandRegistering`), so the lock screen, Control Center, and a CarPlay head unit all
///   drive the same controller code the in-app buttons do.
///
/// `@MainActor` because it is UI-facing state (the detail button and the CarPlay Now Playing template
/// both observe it) and the media-center seams are main-actor. An `ObservableObject` so SwiftUI can
/// bind to `isPlaying`.
@MainActor
final class ThoughtPlaybackController: ObservableObject {
    /// True while a recording is playing (not paused, not stopped). The detail button toggles on it.
    @Published private(set) var isPlaying = false
    /// True while a recording is loaded but paused, so a surface can show resume vs. start-over.
    @Published private(set) var isPaused = false

    /// The thought currently loaded for playback, or nil when nothing is loaded. CarPlay reads it to
    /// title its Now Playing template, and the now-playing bar (spec 0015) binds to it to know whether
    /// to show and what title to render. `@Published` so a SwiftUI surface refreshes when the loaded
    /// thought changes - on a fresh play, a queue advance, or a stop.
    @Published private(set) var currentThought: Thought?

    /// The queued thoughts a folder swipe started (spec 0015), in play order, and the index of the one
    /// currently playing. Empty (index 0) when no queue is active - a single-thought `play(thought:)` does
    /// not populate it. The natural end-of-track path (`handleFinish`) advances `queueIndex` and starts
    /// the next entry until the queue is exhausted, then clears both. Kept private so the queue can
    /// only be driven through `playQueue` / `playNext` / `stop`.
    private var queue: [Thought] = []
    private var queueIndex = 0

    /// Whether a next queued thought exists after the current one (spec 0015): the now-playing bar shows
    /// its Next button only while this is true. `@Published` so the bar hides Next the instant the
    /// queue reaches its last entry. False whenever no queue is active.
    @Published private(set) var hasNext = false

    /// Seconds elapsed in the loaded recording (spec 0027), refreshed live by the progress ticker while
    /// playing and immediately on a seek / skip, so the bottom player's progress bar and elapsed label
    /// track playback. Zero when nothing is loaded.
    @Published private(set) var elapsed: Double = 0

    /// The loaded recording's total length in seconds (spec 0027), from the thought's `recordingDuration`.
    /// The bottom player's slider spans `[0, duration]` and the remaining label counts down against it.
    /// Zero when nothing is loaded.
    @Published private(set) var duration: Double = 0

    /// The live-progress ticker (spec 0027): a lightweight loop that samples `player.currentTime` into
    /// `elapsed` and refreshes Now Playing while playing, so the in-app bar and the system Dynamic Island /
    /// lock screen advance without waiting for a transport event. Started on play/resume, cancelled on
    /// pause/stop/finish. Nil while not ticking.
    private var progressTicker: Task<Void, Never>?
    /// How often the progress ticker samples the player position. A quarter second reads smoothly on the
    /// bar without busy-spinning.
    private let progressTickInterval: Duration = .milliseconds(250)

    /// An opaque handle to a registered transport-change observer, returned by
    /// `addTransportObserver` and passed back to `removeTransportObserver` to unregister.
    struct TransportObserverToken: Hashable {
        fileprivate let value: UInt64
    }

    /// The registered transport-change observers, keyed by token. MULTICAST by design: this ONE
    /// controller is shared across surfaces (the phone `ThoughtPlaybackModel` projection and the CarPlay
    /// scene both drive and observe it), so more than one headless observer is live at once. A single
    /// slot would let one surface clobber the other's callback - so each registers/unregisters its own
    /// entry here and every entry is fanned out on a transport change.
    private var transportObservers: [TransportObserverToken: () -> Void] = [:]
    /// Monotonic source for observer tokens, so each registration gets a distinct, non-reused key.
    private var nextObserverToken: UInt64 = 0

    private let resolver: AudioURLResolving
    private let player: AudioThoughtPlayer
    private let nowPlaying: NowPlayingInfoWriting
    private let remote: RemoteCommandRegistering
    /// The user's lock-screen title preference, read at publish time so a Settings toggle applies to
    /// the very next Now Playing update. `.generic` hides a sensitive first line behind a fixed label.
    private let lockScreenTitle: () -> LockScreenTitle
    /// Relative skip step in seconds, matching the interval advertised to the system.
    private let skipInterval: Double

    /// The in-flight resolve+play, tracked so a rapid re-play cancels the first rather than racing.
    private var pendingPlay: Task<Void, Never>?

    /// True while WE are tearing the player down (stop, or a switch to a new thought), so the player's
    /// `onFinish` - which `player.stop()` fires synchronously - does not run the natural end-of-track
    /// teardown on top of the deliberate one.
    private var suppressFinish = false

    init(
        resolver: AudioURLResolving,
        player: AudioThoughtPlayer? = nil,
        nowPlaying: NowPlayingInfoWriting? = nil,
        remote: RemoteCommandRegistering? = nil,
        lockScreenTitle: @escaping () -> LockScreenTitle = { .default },
        skipInterval: Double = defaultSkipInterval
    ) {
        self.resolver = resolver
        self.player = player ?? SystemAudioThoughtPlayer()
        self.nowPlaying = nowPlaying ?? SystemNowPlayingInfoWriter()
        self.remote = remote ?? SystemRemoteCommandRegistrar()
        self.lockScreenTitle = lockScreenTitle
        self.skipInterval = skipInterval
        self.player.onFinish = { [weak self] in self?.handleFinish() }
    }

    /// Register an observer fired (on the main actor) after any transport-state change - play, pause,
    /// resume, skip, stop, natural finish - so a surface can refresh its own view of the controller.
    /// Multi-observer safe: the phone projection and the CarPlay scene can both observe the one shared
    /// controller without clobbering each other. Returns a token to pass to `removeTransportObserver`.
    @discardableResult
    func addTransportObserver(_ observer: @escaping () -> Void) -> TransportObserverToken {
        let token = TransportObserverToken(value: nextObserverToken)
        nextObserverToken += 1
        transportObservers[token] = observer
        return token
    }

    /// Unregister a transport-change observer previously added via `addTransportObserver`.
    func removeTransportObserver(_ token: TransportObserverToken) {
        transportObservers.removeValue(forKey: token)
    }

    /// Fan a transport change out to every registered observer. A snapshot of the values is iterated
    /// so an observer that removes itself during the callback does not mutate the collection mid-loop.
    private func notifyTransportChange() {
        for observer in transportObservers.values { observer() }
    }

    /// Whether the controller is loaded for `thought` (its recording is the one playing / paused).
    func isLoaded(_ thought: Thought) -> Bool { currentThought?.id == thought.id }

    /// The loaded thought's own title for the now-playing bar (spec 0015), or nil when nothing is loaded.
    /// This is the in-app bar's label and is independent of the lock-screen-title preference, which
    /// only governs what leaves the device to Now Playing / CarPlay.
    var currentTitle: String? { currentThought?.title }

    /// Start playing `thought`'s recording from the top, wiring Now Playing and remote commands. Resolves
    /// the URL off the main actor at play time (coordinated presence can block). Optimistically flips
    /// to "playing" so a button responds immediately; a missing or unplayable file clears it. A no-op
    /// for a thought that claims no recording.
    func play(thought: Thought) {
        // Guard BEFORE tearing down the current playback: a no-audio thought must not stop whatever is
        // playing and then bail, which would strand the old thought in Now Playing with live remote
        // handlers wired to a stopped controller.
        guard thought.hasAudio else { return }
        // A DIRECT single-thought play (a thought swipe, the detail button) ends any running queue - it is a
        // deliberate new selection, not a queue advance - so a later natural finish does not resume an
        // orphaned queue. `playQueue` / `advanceQueue` call `loadAndPlay` instead, past this line, so
        // their queue state survives.
        clearQueue()
        loadAndPlay(thought: thought)
    }

    /// The shared start path used by both a direct `play(thought:)` and a queue advance: cancel any
    /// in-flight resolve, clear the current playback, load `thought`, and kick off the off-main resolve.
    /// Split out so the queue can advance without wiping the queue bookkeeping `play(thought:)` clears.
    private func loadAndPlay(thought: Thought) {
        pendingPlay?.cancel()
        // Different thought (or a fresh start): fully clear the current playback (player, Now Playing,
        // remote) before loading the new one, so no stale metadata or wiring survives the switch.
        clearPlayback()

        currentThought = thought
        isPlaying = true
        isPaused = false
        // Publish the known length immediately (from the thought's timings) and reset elapsed, so the bar
        // shows a full-width progress track before the off-main resolve completes.
        duration = thought.recordingDuration
        elapsed = 0
        notifyTransportChange()

        let resolver = resolver
        let thoughtID = thought.id
        let audioFileName = thought.audioFileName
        pendingPlay = Task { [weak self] in
            let url = await Task.detached {
                resolver.resolveAudioURL(for: thoughtID, audioFileName: audioFileName)
            }.value
            guard !Task.isCancelled else { return }
            self?.startPlayback(thought: thought, url: url)
        }
    }

    /// Start playing an ORDERED queue of thoughts (spec 0015), one at a time, auto-advancing on each
    /// natural finish. The list is filtered to thoughts that actually carry a recording (`hasAudio`), in
    /// the order given (the caller sorts by the current `ThoughtSortOrder`); text-only thoughts are skipped.
    /// With no recorded thought the whole call is a no-op - nothing playing is disturbed. Otherwise it
    /// sets the queue, wires the bar's `hasNext`, and plays the first entry through the SAME single
    /// `play(thought:)` path (one audio path, one Now Playing writer), so only "which thought is current"
    /// differs from a single play.
    func playQueue(_ thoughts: [Thought]) {
        let playable = thoughts.filter(\.hasAudio)
        guard !playable.isEmpty else { return }
        queue = playable
        queueIndex = 0
        hasNext = playable.count > 1
        // `loadAndPlay` clears any prior playback first, then loads the first entry and fires the
        // transport change so the bar appears. It does NOT clear the queue (unlike the public
        // `play(thought:)`), so the queue we just set survives.
        loadAndPlay(thought: playable[0])
    }

    /// Skip to the next queued thought (spec 0015), or stop when the current one is the last (or no queue
    /// is active). Distinct from the natural-finish advance in that the USER asked for it: it clears
    /// the current playback and starts the next entry immediately. A no-op-to-stop when there is no
    /// next, matching the bar hiding its Next button at the end of the queue.
    /// Skip to the next queued recording (the now-playing bar's Next button), or stop if this is the
    /// last. This is a PHONE-BAR-ONLY affordance: the system remote (lock screen / Control Center /
    /// CarPlay) intentionally maps skip to a 15s SEEK (`skipForward`/`skipBackward`), not a track
    /// change, so do NOT wire a remote `nextTrackCommand` to this (architect review).
    func playNext() {
        guard hasNext, queueIndex + 1 < queue.count else {
            stop()
            return
        }
        advanceQueue()
    }

    /// Toggle for the in-app button: pause if playing, resume if paused, otherwise (re)start the
    /// loaded thought. With no loaded thought this is a no-op.
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else if isPaused {
            resume()
        } else if let thought = currentThought {
            play(thought: thought)
        }
    }

    /// Pause playback in place, keeping Now Playing visible with rate 0 so the lock screen shows a
    /// paused item that can be resumed.
    func pause() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        isPaused = true
        stopProgressTicker()
        publishNowPlaying()
        notifyTransportChange()
    }

    /// Resume playback paused by `pause()`. A no-op when not paused.
    func resume() {
        guard isPaused, player.resume() else { return }
        isPlaying = true
        isPaused = false
        startProgressTicker()
        publishNowPlaying()
        notifyTransportChange()
    }

    /// Skip `by` seconds relative to the current position (negative to go back), clamped into the
    /// recording (spec 0027): a skip-forward past the end pins to the duration, a skip-back below 0 pins
    /// to 0. Only meaningful while a recording is loaded.
    func skip(by seconds: Double) {
        guard currentThought != nil, isPlaying || isPaused else { return }
        seek(to: player.currentTime + seconds)
    }

    /// Seek to an ABSOLUTE position `time` seconds into the recording (spec 0027): the in-app slider drag
    /// and the system UI's scrubber both call this. Clamped into `[0, duration]` (the same rule the player
    /// applies, expressed once in `PlaybackProgress`) so a drag past either end lands in range. Updates the
    /// published elapsed and Now Playing immediately so the bar and lock screen reflect the new position
    /// without waiting for the next tick. Only meaningful while a recording is loaded.
    func seek(to time: Double) {
        guard currentThought != nil, isPlaying || isPaused else { return }
        let target = PlaybackProgress.clamp(time, duration: duration)
        player.seek(to: target)
        elapsed = target
        publishNowPlaying()
        notifyTransportChange()
    }

    /// Stop playback, clear Now Playing, and drop the remote commands so nothing is left wired to a
    /// gone recording. Safe to call when idle.
    func stop() {
        pendingPlay?.cancel()
        pendingPlay = nil
        // A user stop ends the whole queue too (spec 0015), so the natural-finish path has no queue to
        // advance into afterward and the bar hides.
        clearQueue()
        clearPlayback()
        notifyTransportChange()
    }

    // MARK: - Private

    /// Begin playback of a resolved URL. A nil or unplayable URL leaves the controller idle rather
    /// than stuck "playing" - and clears any Now Playing / remote wiring so a failed play never
    /// strands stale metadata.
    private func startPlayback(thought: Thought, url: URL?) {
        pendingPlay = nil
        guard let url, player.play(url: url, from: 0, duration: nil) else {
            // A nil / unplayable recording must not strand a running queue: skip it to the next entry,
            // or clear out cleanly when there is nothing more to play - the same advance-or-teardown a
            // natural end uses (spec 0015 review). With no queue this simply clears, as before.
            advanceOrFinish()
            return
        }
        isPlaying = true
        isPaused = false
        elapsed = player.currentTime
        startProgressTicker()
        wireRemoteCommands()
        publishNowPlaying()
        notifyTransportChange()
    }

    /// Wire the transport commands to this controller so the lock screen / CarPlay drive the same
    /// code the in-app buttons do. Registered once per play; `unregisterAll` on stop tears them down.
    private func wireRemoteCommands() {
        remote.register(
            play: { [weak self] in self?.resume() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.togglePlayPause() },
            stop: { [weak self] in self?.stop() },
            skipForward: { [weak self] in self?.skip(by: self?.skipInterval ?? 0) },
            skipBackward: { [weak self] in self?.skip(by: -(self?.skipInterval ?? 0)) },
            scrub: { [weak self] position in self?.seek(to: position) }
        )
    }

    /// Start the live-progress ticker (spec 0027): sample the player position into `elapsed` and refresh
    /// Now Playing every tick while playing, so the bar and the system Dynamic Island / lock screen
    /// advance smoothly. Cancels any prior ticker first (idempotent), and stops itself the moment
    /// playback is no longer active. Does NOT fire the transport multicast per tick - `elapsed` is
    /// `@Published`, so a SwiftUI bar observing it refreshes on its own without a per-tick fan-out.
    private func startProgressTicker() {
        progressTicker?.cancel()
        progressTicker = Task { [weak self] in
            guard let interval = self?.progressTickInterval else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                guard let self, self.isPlaying else { return }
                self.elapsed = self.player.currentTime
                self.publishNowPlaying()
            }
        }
    }

    /// Stop the live-progress ticker (on pause / stop / finish) so it does not keep sampling a
    /// paused-or-gone player.
    private func stopProgressTicker() {
        progressTicker?.cancel()
        progressTicker = nil
    }

    /// Publish the current Now Playing metadata from the loaded thought and the player's position. The
    /// title honors the user's lock-screen-title preference (read here, so a Settings toggle applies
    /// to the next update): `.generic` publishes a fixed label instead of the thought's own first line so
    /// a sensitive title does not appear on the lock screen / Control Center / CarPlay.
    private func publishNowPlaying() {
        guard let thought = currentThought else {
            nowPlaying.update(nil)
            return
        }
        nowPlaying.update(NowPlayingInfo(
            title: lockScreenTitle().nowPlayingTitle(for: thought.title),
            duration: thought.recordingDuration,
            elapsed: player.currentTime,
            rate: isPlaying ? 1 : 0
        ))
    }

    /// The player reached the end on its own: clear state, Now Playing, and the remote wiring. When
    /// WE initiated the stop (`suppressFinish`), the caller (`clearPlayback`) already reset the
    /// transport flags and torn down Now Playing / remote, so this is a no-op in that case - the
    /// reset moved below the guard so it does not run redundantly on top of the deliberate teardown.
    private func handleFinish() {
        guard !suppressFinish else { return }
        // Only a NATURAL end reaches here - a user stop sets `suppressFinish` (via `clearPlayback`) and
        // returned above - so this is exactly "the current recording ended on its own".
        advanceOrFinish()
    }

    /// Advance to the next queued recording, or - when there is no queue or it is exhausted - tear
    /// everything down (state, Now Playing, remote, queue) so the bar hides. Shared by the natural
    /// end-of-track (`handleFinish`) AND a failed/unplayable resolve (`startPlayback`): a recording
    /// that ends and one that cannot be played both move the queue forward rather than STRANDING it
    /// (a folder swipe plays through, skipping a missing file - engineer/tester review).
    private func advanceOrFinish() {
        if !queue.isEmpty && queueIndex + 1 < queue.count {
            advanceQueue()
            return
        }
        clearQueue()
        resetState()
        currentThought = nil
        nowPlaying.update(nil)
        remote.unregisterAll()
        notifyTransportChange()
    }

    /// Move to the next queued thought and start it through the shared `play(thought:)` path. `play(thought:)`
    /// clears the current playback (player, Now Playing, remote) and reloads for the next thought, but
    /// leaves `queue` untouched, so we bump the index and recompute `hasNext` around it. Used by both
    /// the natural-finish advance and the user's Next button.
    private func advanceQueue() {
        queueIndex += 1
        hasNext = queueIndex + 1 < queue.count
        loadAndPlay(thought: queue[queueIndex])
    }

    /// Drop the active queue so no stale ordering survives a stop or the end of a queue. Leaves the
    /// player / Now Playing / remote to the caller; this is only the queue bookkeeping the bar reads.
    private func clearQueue() {
        queue = []
        queueIndex = 0
        hasNext = false
    }

    /// Fully clear playback: stop the player, drop the loaded thought, and clear the Now Playing item +
    /// remote wiring, so nothing stale survives a stop or a switch to another thought. Suppresses the
    /// synchronous `onFinish` that `player.stop()` fires so it does not run the natural-end teardown
    /// on top of this deliberate one. Does NOT itself notify observers - the caller does, once.
    private func clearPlayback() {
        if isPlaying || isPaused {
            suppressFinish = true
            player.stop()
            suppressFinish = false
        }
        resetState()
        currentThought = nil
        nowPlaying.update(nil)
        remote.unregisterAll()
    }

    private func resetState() {
        isPlaying = false
        isPaused = false
        // Stop the live-progress ticker and clear the published progress so a torn-down or switched
        // player leaves the bar with no stale elapsed/duration (spec 0027). `loadAndPlay` re-seeds
        // duration for the next thought.
        stopProgressTicker()
        elapsed = 0
        duration = 0
    }
}
