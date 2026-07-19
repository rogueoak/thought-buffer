import Foundation
import AVFoundation
import Combine

/// Plays a thought's recording on the watch (spec 0023, browse + play). The audio is fetched on demand
/// from the phone (`WatchConnectivityManager.requestAudio`) and cached briefly; this wraps `AVAudioPlayer`
/// with the playback session handling the watch speaker needs. Observable so the detail view reflects the
/// play / stop state.
@MainActor
final class WatchAudioPlayer: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false

    private var player: AVAudioPlayer?

    /// Play the audio file at `url`. Returns false when it cannot be opened (e.g. a not-yet-arrived
    /// transfer), so the caller can keep waiting or show a message.
    @discardableResult
    func play(url: URL) -> Bool {
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            guard player.play() else { return false }
            self.player = player
            isPlaying = true
            return true
        } catch {
            return false
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}

extension WatchAudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.player = nil
        }
    }
}
