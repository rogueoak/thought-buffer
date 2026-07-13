import Foundation

/// The speech-capture surface the dictation view model depends on.
///
/// The view model talks to this protocol rather than the concrete `SpeechDictationService`, so
/// later milestones (or tests) can drop in a different capture backend without touching the view
/// model. The production implementation is `SpeechDictationService`.
@MainActor
protocol SpeechCaptureService: AnyObject {
    /// Called for every capture event, on the main actor. Set before `start()`.
    var onEvent: ((SpeechCaptureEvent) -> Void)? { get set }

    /// Request speech + microphone authorization. Returns nil on success, or the first blocking
    /// error otherwise.
    func requestAuthorization() async -> SpeechCaptureError?

    /// Whether on-device recognition is possible right now. Returns the blocking error or nil.
    func availabilityError() -> SpeechCaptureError?

    /// Begin capturing. Assumes authorization has already been granted.
    func start()

    /// Pause capture, keeping any note the caller is holding.
    func pause()

    /// Resume after a pause.
    func resume()

    /// Stop capture entirely and release the audio session.
    func stop()
}

/// Events a capture service reports back to its consumer, always on the main actor.
enum SpeechCaptureEvent {
    /// The in-progress phrase for the current task (replaces the last partial).
    case partial(String)
    /// A finalized phrase that should be committed to the note as a paragraph.
    case finalizedSegment(String)
    /// Microphone input level, 0...1, for the waveform.
    case level(Float)
    /// A user-facing failure. Capture has stopped.
    case failure(SpeechCaptureError)
}

/// Reasons capture cannot proceed, each mapped to friendly copy in the UI.
///
/// The `engineFailure` case carries the raw error string for logging only; user-facing copy is
/// derived from the case, never from this string (see `DictationViewModel.DeniedReason`).
enum SpeechCaptureError: Equatable {
    case speechNotAuthorized
    case microphoneNotAuthorized
    case onDeviceUnavailable
    case recognizerUnavailable
    case engineFailure(String)
}
