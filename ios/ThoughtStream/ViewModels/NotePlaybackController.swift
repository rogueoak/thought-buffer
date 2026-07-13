import Foundation

/// The one headless audio playback path for a saved note's recording (spec 0008).
///
/// Both the phone detail view (through `NotePlaybackModel`) and the CarPlay scene drive THIS type, so
/// there is exactly one place that talks to the `AudioNotePlayer` and one writer of
/// `MPNowPlayingInfoCenter`. It owns:
///
/// - lazy, off-main URL resolution via `AudioURLResolving` (a recording can be swept or synced away
///   between navigation and play, and the iCloud presence check can block, so it is resolved at play
///   time on a detached task, exactly as spec 0007's model did);
/// - play / pause / resume / stop / relative-skip over the whole recording via `AudioNotePlayer`;
/// - the system Now Playing metadata (`NowPlayingInfoWriting`) and remote transport commands
///   (`RemoteCommandRegistering`), so the lock screen, Control Center, and a CarPlay head unit all
///   drive the same controller code the in-app buttons do.
///
/// `@MainActor` because it is UI-facing state (the detail button and the CarPlay Now Playing template
/// both observe it) and the media-center seams are main-actor. An `ObservableObject` so SwiftUI can
/// bind to `isPlaying`.
@MainActor
final class NotePlaybackController: ObservableObject {
    /// True while a recording is playing (not paused, not stopped). The detail button toggles on it.
    @Published private(set) var isPlaying = false
    /// True while a recording is loaded but paused, so a surface can show resume vs. start-over.
    @Published private(set) var isPaused = false

    /// The note currently loaded for playback, or nil when nothing is loaded. CarPlay reads it to
    /// title its Now Playing template.
    private(set) var currentNote: Note?

    /// An opaque handle to a registered transport-change observer, returned by
    /// `addTransportObserver` and passed back to `removeTransportObserver` to unregister.
    struct TransportObserverToken: Hashable {
        fileprivate let value: UInt64
    }

    /// The registered transport-change observers, keyed by token. MULTICAST by design: this ONE
    /// controller is shared across surfaces (the phone `NotePlaybackModel` projection and the CarPlay
    /// scene both drive and observe it), so more than one headless observer is live at once. A single
    /// slot would let one surface clobber the other's callback - so each registers/unregisters its own
    /// entry here and every entry is fanned out on a transport change.
    private var transportObservers: [TransportObserverToken: () -> Void] = [:]
    /// Monotonic source for observer tokens, so each registration gets a distinct, non-reused key.
    private var nextObserverToken: UInt64 = 0

    private let resolver: AudioURLResolving
    private let player: AudioNotePlayer
    private let nowPlaying: NowPlayingInfoWriting
    private let remote: RemoteCommandRegistering
    /// The user's lock-screen title preference, read at publish time so a Settings toggle applies to
    /// the very next Now Playing update. `.generic` hides a sensitive first line behind a fixed label.
    private let lockScreenTitle: () -> LockScreenTitle
    /// Relative skip step in seconds, matching the interval advertised to the system.
    private let skipInterval: Double

    /// The in-flight resolve+play, tracked so a rapid re-play cancels the first rather than racing.
    private var pendingPlay: Task<Void, Never>?

    /// True while WE are tearing the player down (stop, or a switch to a new note), so the player's
    /// `onFinish` - which `player.stop()` fires synchronously - does not run the natural end-of-track
    /// teardown on top of the deliberate one.
    private var suppressFinish = false

    init(
        resolver: AudioURLResolving,
        player: AudioNotePlayer? = nil,
        nowPlaying: NowPlayingInfoWriting? = nil,
        remote: RemoteCommandRegistering? = nil,
        lockScreenTitle: @escaping () -> LockScreenTitle = { .default },
        skipInterval: Double = defaultSkipInterval
    ) {
        self.resolver = resolver
        self.player = player ?? SystemAudioNotePlayer()
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

    /// Whether the controller is loaded for `note` (its recording is the one playing / paused).
    func isLoaded(_ note: Note) -> Bool { currentNote?.id == note.id }

    /// Start playing `note`'s recording from the top, wiring Now Playing and remote commands. Resolves
    /// the URL off the main actor at play time (coordinated presence can block). Optimistically flips
    /// to "playing" so a button responds immediately; a missing or unplayable file clears it. A no-op
    /// for a note that claims no recording.
    func play(note: Note) {
        // Guard BEFORE tearing down the current playback: a no-audio note must not stop whatever is
        // playing and then bail, which would strand the old note in Now Playing with live remote
        // handlers wired to a stopped controller.
        guard note.hasAudio else { return }
        pendingPlay?.cancel()
        // Different note (or a fresh start): fully clear the current playback (player, Now Playing,
        // remote) before loading the new one, so no stale metadata or wiring survives the switch.
        clearPlayback()

        currentNote = note
        isPlaying = true
        isPaused = false
        notifyTransportChange()

        let resolver = resolver
        let noteID = note.id
        let audioFileName = note.audioFileName
        pendingPlay = Task { [weak self] in
            let url = await Task.detached {
                resolver.resolveAudioURL(for: noteID, audioFileName: audioFileName)
            }.value
            guard !Task.isCancelled else { return }
            self?.startPlayback(note: note, url: url)
        }
    }

    /// Toggle for the in-app button: pause if playing, resume if paused, otherwise (re)start the
    /// loaded note. With no loaded note this is a no-op.
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else if isPaused {
            resume()
        } else if let note = currentNote {
            play(note: note)
        }
    }

    /// Pause playback in place, keeping Now Playing visible with rate 0 so the lock screen shows a
    /// paused item that can be resumed.
    func pause() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        isPaused = true
        publishNowPlaying()
        notifyTransportChange()
    }

    /// Resume playback paused by `pause()`. A no-op when not paused.
    func resume() {
        guard isPaused, player.resume() else { return }
        isPlaying = true
        isPaused = false
        publishNowPlaying()
        notifyTransportChange()
    }

    /// Skip `by` seconds relative to the current position (negative to go back), then keep the
    /// transport state. Only meaningful while a recording is loaded.
    func skip(by seconds: Double) {
        guard currentNote != nil, isPlaying || isPaused else { return }
        player.seek(to: player.currentTime + seconds)
        publishNowPlaying()
        notifyTransportChange()
    }

    /// Stop playback, clear Now Playing, and drop the remote commands so nothing is left wired to a
    /// gone recording. Safe to call when idle.
    func stop() {
        pendingPlay?.cancel()
        pendingPlay = nil
        clearPlayback()
        notifyTransportChange()
    }

    // MARK: - Private

    /// Begin playback of a resolved URL. A nil or unplayable URL leaves the controller idle rather
    /// than stuck "playing" - and clears any Now Playing / remote wiring so a failed play never
    /// strands stale metadata.
    private func startPlayback(note: Note, url: URL?) {
        pendingPlay = nil
        guard let url, player.play(url: url, from: 0, duration: nil) else {
            clearPlayback()
            notifyTransportChange()
            return
        }
        isPlaying = true
        isPaused = false
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
            skipBackward: { [weak self] in self?.skip(by: -(self?.skipInterval ?? 0)) }
        )
    }

    /// Publish the current Now Playing metadata from the loaded note and the player's position. The
    /// title honors the user's lock-screen-title preference (read here, so a Settings toggle applies
    /// to the next update): `.generic` publishes a fixed label instead of the note's own first line so
    /// a sensitive title does not appear on the lock screen / Control Center / CarPlay.
    private func publishNowPlaying() {
        guard let note = currentNote else {
            nowPlaying.update(nil)
            return
        }
        nowPlaying.update(NowPlayingInfo(
            title: lockScreenTitle().nowPlayingTitle(for: note.title),
            duration: note.recordingDuration,
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
        resetState()
        currentNote = nil
        nowPlaying.update(nil)
        remote.unregisterAll()
        notifyTransportChange()
    }

    /// Fully clear playback: stop the player, drop the loaded note, and clear the Now Playing item +
    /// remote wiring, so nothing stale survives a stop or a switch to another note. Suppresses the
    /// synchronous `onFinish` that `player.stop()` fires so it does not run the natural-end teardown
    /// on top of this deliberate one. Does NOT itself notify observers - the caller does, once.
    private func clearPlayback() {
        if isPlaying || isPaused {
            suppressFinish = true
            player.stop()
            suppressFinish = false
        }
        resetState()
        currentNote = nil
        nowPlaying.update(nil)
        remote.unregisterAll()
    }

    private func resetState() {
        isPlaying = false
        isPaused = false
    }
}
