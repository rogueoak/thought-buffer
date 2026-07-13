import Foundation
import AVFoundation

/// Plays back a note's recording, optionally seeking to a paragraph's time range (spec 0007).
///
/// The view model talks to this protocol rather than `AVAudioPlayer` directly, so tests can inject a
/// stub and assert what range was played, and so "read that back" can fall back to the text-to-speech
/// `Speaker` when a note has no audio. The production implementation is `SystemAudioNotePlayer`.
///
/// `onFinish` fires when playback reaches its end (or the ranged stop point) or is stopped, always on
/// the main actor, so the caller resumes capture on "playback finished" the same way it does for the
/// speaker - the record -> playback -> record handshake stays event-driven.
@MainActor
protocol AudioNotePlayer: AnyObject {
    /// Called when playback finishes or is stopped.
    var onFinish: (() -> Void)? { get set }

    /// Play the recording at `url`, starting at `start` seconds. When `duration` is non-nil, playback
    /// stops after that many seconds (a paragraph range); when nil, it plays to the end of the file.
    /// Returns false when the file cannot be played (missing or unreadable), so the caller can fall
    /// back to text-to-speech.
    @discardableResult
    func play(url: URL, from start: Double, duration: Double?) -> Bool

    /// Stop any in-progress playback immediately.
    func stop()
}

/// `AVAudioPlayer`-backed player.
///
/// Sets the audio session to `.playback` for the duration (matching `SystemSpeaker`) so the spoken
/// audio does not fight the record session, seeks with `currentTime`, and - because `AVAudioPlayer`
/// has no native stop-at-time - schedules a lightweight timer to stop at the end of a paragraph
/// range. Completion is reported through `onFinish` for both the full-play and ranged-play cases.
@MainActor
final class SystemAudioNotePlayer: NSObject, AudioNotePlayer, AVAudioPlayerDelegate {
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
            rangeStopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        }
        return true
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
