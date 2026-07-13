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

    /// Turn the tee'd audio recording on or off for the session that `start()` will begin (spec
    /// 0007). Set BEFORE `start()`. When true, the same input-tap buffers that feed recognition are
    /// also written to a compressed `.m4a`; when false (transcript-only), no audio file is opened.
    /// Defaults to off so a caller that never sets it behaves exactly as before.
    func setRecordingEnabled(_ enabled: Bool)

    /// The URL of the recording written for the session, or nil when nothing was recorded (recording
    /// disabled, or capture never wrote a frame). Valid after `stop()`; the file is a temporary one
    /// the caller adopts into storage via `NoteStoring.saveAudio(from:for:)`.
    func recordingURL() -> URL?

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
    /// A finalized phrase that should be committed to the note as a paragraph, with its time range
    /// in the recording (spec 0007). `range` is nil when nothing was recorded (recording disabled,
    /// or the recognizer reported no segment timings) so a text-only session is unaffected.
    case finalizedSegment(String, range: ParagraphTiming?)
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
