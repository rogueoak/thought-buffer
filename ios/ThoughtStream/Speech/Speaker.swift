import Foundation
import AVFoundation

/// Text-to-speech surface used by the "read that back" command.
///
/// The view model talks to this protocol rather than `AVSpeechSynthesizer` directly, so tests can
/// inject a stub and assert what was spoken. The production implementation is `SystemSpeaker`.
///
/// `onFinish` is called when an utterance finishes or is cancelled, so the caller resumes capture
/// on "speech finished" rather than guessing a duration. It is always delivered on the main actor.
@MainActor
protocol Speaker: AnyObject {
    /// Called when the current utterance finishes or is cancelled.
    var onFinish: (() -> Void)? { get set }

    /// Speak `text` aloud. A no-op for empty text.
    func speak(_ text: String)

    /// Stop any in-progress speech immediately.
    func stop()
}

/// `AVSpeechSynthesizer`-backed speaker.
///
/// Sets the audio session to `.playback` for the utterance so the record session (see
/// the speech service) is out of the way while Mira speaks, and reports completion through
/// `onFinish` so the view model can restore capture cleanly.
@MainActor
final class SystemSpeaker: NSObject, Speaker, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onFinish?()
            return
        }
        // Route to playback so the spoken audio does not fight the record session. The record
        // session is deactivated by the caller (via capture pause) before we get here.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)

        let utterance = AVSpeechUtterance(string: trimmed)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.finish() }
    }

    private func finish() {
        // Deactivate the playback session before handing back, so a read-back fired while paused
        // does not leave other apps ducked. Notify others so they can resume. The view model's
        // resume path reactivates the record session when capture was recording.
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        onFinish?()
    }
}
