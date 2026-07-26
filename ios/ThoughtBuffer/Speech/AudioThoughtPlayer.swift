import Foundation
import AVFoundation

/// Plays back a thought's recording, optionally seeking to a paragraph's time range (spec 0007).
///
/// The view model talks to this protocol rather than `AVAudioPlayer` directly, so tests can inject a
/// stub and assert what range was played, and so "read that back" can fall back to the text-to-speech
/// `Speaker` when a thought has no audio. The production implementation is `SystemAudioThoughtPlayer`.
///
/// `onFinish` fires when playback reaches its end (or the ranged stop point) or is stopped, always on
/// the main actor, so the caller resumes capture on "playback finished" the same way it does for the
/// speaker - the record -> playback -> record handshake stays event-driven.
@MainActor
protocol AudioThoughtPlayer: AnyObject {
    /// Called when playback finishes or is stopped.
    var onFinish: (() -> Void)? { get set }

    /// Play the recording at `url`, starting at `start` seconds. When `duration` is non-nil, playback
    /// stops after that many seconds (a paragraph range); when nil, it plays to the end of the file.
    /// Returns false when the file cannot be played (missing or unreadable), so the caller can fall
    /// back to text-to-speech.
    @discardableResult
    func play(url: URL, from start: Double, duration: Double?) -> Bool

    /// Pause in-progress playback in place, keeping the loaded file and position so `resume()` can
    /// continue. A no-op when nothing is playing. Does NOT fire `onFinish` (playback is not over).
    func pause()

    /// Resume playback paused by `pause()` from where it left off. Returns false when there is
    /// nothing to resume (never played, or already stopped). A no-op / false when already playing.
    @discardableResult
    func resume() -> Bool

    /// Stop any in-progress playback immediately.
    func stop()

    /// Seconds elapsed from the start of the file for the loaded recording, or 0 when nothing is
    /// loaded. Read by the playback controller to publish Now Playing elapsed and to seek on skip.
    var currentTime: Double { get }

    /// Seek the loaded recording to `time` seconds (clamped into the file). A no-op when nothing is
    /// loaded. Used by relative skip.
    func seek(to time: Double)
}

/// `AVAudioPlayer`-backed player.
///
/// Sets the audio session to `.playback` for the duration (matching `SystemSpeaker`) so the spoken
/// audio does not fight the record session, seeks with `currentTime`, and - because `AVAudioPlayer`
/// has no native stop-at-time - schedules a lightweight timer to stop at the end of a paragraph
/// range. Completion is reported through `onFinish` for both the full-play and ranged-play cases.
@MainActor
final class SystemAudioThoughtPlayer: NSObject, AudioThoughtPlayer, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    private var player: AVAudioPlayer?
    /// Stops a ranged play at the end of its window, since `AVAudioPlayer` plays to the file end.
    private var rangeStopTask: Task<Void, Never>?

    @discardableResult
    func play(url: URL, from start: Double, duration: Double?) -> Bool {
        stop()

        guard let player = try? AVAudioPlayer(contentsOf: url) else { return false }
        player.delegate = self
        player.prepareToPlay()

        // Route to playback so the audio does not fight the record session, mirroring `SystemSpeaker`.
        // The record session is deactivated by the caller (via capture pause) before we get here.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)

        // Clamp the seek into the file so a slightly-off timing never fails the play.
        player.currentTime = max(0, min(start, player.duration))
        self.player = player
        guard player.play() else {
            self.player = nil
            return false
        }

        if let duration, duration > 0 {
            // No native stop-at-time on AVAudioPlayer, so stop the ranged window ourselves.
            // TODO(CarPlay waveform milestone): a `Task.sleep` timer is coarse for tight per-paragraph
            // ranges; the waveform scrubber will need frame-accurate stop-at-time (e.g. a display-link
            // or `AVPlayer` boundary observer). Out of scope here.
            rangeStopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        }
        return true
    }

    func pause() {
        // Cancel the ranged-stop timer while paused so it does not fire mid-pause; full-thought playback
        // (the CarPlay / Now Playing path) has no timer, so this only matters for a ranged play.
        rangeStopTask?.cancel()
        rangeStopTask = nil
        guard let player, player.isPlaying else { return }
        player.pause()
        // No `onFinish` - playback is suspended, not over.
    }

    @discardableResult
    func resume() -> Bool {
        guard let player, !player.isPlaying else { return false }
        // Reactivate the playback session in case a pause deactivated it, mirroring `play`.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        return player.play()
    }

    var currentTime: Double { player?.currentTime ?? 0 }

    func seek(to time: Double) {
        guard let player else { return }
        // Clamp into the file so a relative skip past either end (skip-back below 0, skip-forward past
        // the duration) lands at a valid position rather than an out-of-range one. `AVAudioPlayer`
        // clamps its own `currentTime`, but the policy is expressed here (and unit-tested via
        // `clampedSeekTime`) so it does not silently depend on that undocumented behavior.
        player.currentTime = Self.clampedSeekTime(time, duration: player.duration)
    }

    /// The seek target clamped into `[0, duration]`. Pure and static so the clamp is unit-testable
    /// without a real `AVAudioPlayer`: a removed clamp would let an out-of-range `time` through, which
    /// the test asserts against directly.
    static func clampedSeekTime(_ time: Double, duration: Double) -> Double {
        max(0, min(time, duration))
    }

    func stop() {
        rangeStopTask?.cancel()
        rangeStopTask = nil
        guard let player else { return }
        self.player = nil
        if player.isPlaying { player.stop() }
        finish()
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            // Only fire if this is still the active player (a ranged stop already cleared it).
            guard self.player === player else { return }
            self.player = nil
            self.rangeStopTask?.cancel()
            self.rangeStopTask = nil
            self.finish()
        }
    }

    private func finish() {
        // Deactivate the playback session before handing back, matching `SystemSpeaker`, so a
        // play fired while paused does not leave other apps ducked. The view model's resume path
        // reactivates the record session when capture was recording.
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        onFinish?()
    }
}
