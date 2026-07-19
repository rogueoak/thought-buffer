import Foundation

/// The speech-capture surface the dictation view model depends on.
///
/// The view model talks to this protocol rather than the concrete `SpeechAnalyzerService`, so
/// later milestones (or tests) can drop in a different capture backend without touching the view
/// model. The production implementation is `SpeechAnalyzerService`.
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

    /// The URL of the recording written for the session, or nil when there is no recording to adopt
    /// (recording disabled, or capture never wrote a frame). Only guaranteed FINALIZED after `stop()`
    /// - the writer is closed at `stop()`, not at `pause()` - so a caller must not play or copy this
    /// file mid-session; it is meant to be adopted into storage via `NoteStoring.saveAudio(from:for:)`
    /// once `stop()` has run.
    func recordingURL() -> URL?

    /// Delete the session's recording temp file, whether or not it has content. Discards a recording
    /// that ends up attached to nothing (a cancelled or empty session), including a zero-frame file
    /// that `recordingURL()` would not report. No-op when there is no recording.
    func discardRecording()

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
    /// A finalized phrase that should be committed to the note (spec 0007), carrying both its ABSOLUTE
    /// recording range and the RAW analysis-relative timing the view model needs to decide paragraph
    /// grouping (feedback 0012).
    ///
    /// - `range`: the paragraph's absolute range in the recording, nil when nothing was recorded
    ///   (recording disabled, or the recognizer reported no segment timings), so a text-only session's
    ///   playback is unaffected.
    /// - `startSeconds` / `durationSeconds`: the segment's time range RELATIVE to the current analysis
    ///   start (from the transcriber `CMTimeRange`). Present even for a text-only session because it is
    ///   relative to analysis, independent of the audio tee. The view model's `ParagraphGrouper` reads
    ///   these (never `range`, which is nil without a recording) to decide flow vs. break by the silence
    ///   gap between consecutive segments.
    /// - `isAnalysisStart`: true for the FIRST finalized result of an analysis. Analysis time resets to
    ///   ~0 across a pause/resume seam, so this flags a resume seam as an unconditional paragraph break
    ///   instead of computing a bogus negative gap across it.
    case finalizedSegment(
        String,
        range: ParagraphTiming?,
        startSeconds: Double,
        durationSeconds: Double,
        isAnalysisStart: Bool
    )
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
