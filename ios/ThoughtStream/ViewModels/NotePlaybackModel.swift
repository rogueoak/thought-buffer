import Foundation
import SwiftUI

/// Drives simple play / stop of a saved note's recording from the detail view (spec 0007).
///
/// Keeps the detail view presentational: it owns an `AudioNotePlayer`, tracks whether playback is
/// running so the button can toggle, and resets on finish. Playback here is the WHOLE note (from the
/// start of the recording to the end), which is why it plays with no duration. Scrubbing, per
/// paragraph play, and rate controls are out of scope for this milestone.
@MainActor
final class NotePlaybackModel: ObservableObject {
    /// True while the recording is playing, so the view shows Stop instead of Play.
    @Published private(set) var isPlaying = false

    /// The note's recording on disk, or nil when the note has no audio (older notes, transcript-only,
    /// or auto-deleted). Nil hides the play affordance entirely.
    let audioURL: URL?

    private let player: AudioNotePlayer

    init(audioURL: URL?, player: AudioNotePlayer? = nil) {
        self.audioURL = audioURL
        self.player = player ?? SystemAudioNotePlayer()
        self.player.onFinish = { [weak self] in
            self?.isPlaying = false
        }
    }

    /// Whether there is a recording to play.
    var canPlay: Bool { audioURL != nil }

    /// Toggle playback: start from the top of the recording, or stop if already playing.
    func toggle() {
        if isPlaying {
            player.stop()
            isPlaying = false
            return
        }
        guard let audioURL else { return }
        // Play the whole recording (nil duration = to the end). `onFinish` clears `isPlaying`.
        if player.play(url: audioURL, from: 0, duration: nil) {
            isPlaying = true
        }
    }

    /// Stop playback if it is running (used when the view disappears).
    func stop() {
        if isPlaying {
            player.stop()
            isPlaying = false
        }
    }
}
