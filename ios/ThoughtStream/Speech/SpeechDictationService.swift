import Foundation
import AVFoundation
import Speech

/// On-device speech-to-text capture. Owns the audio engine, the recognizer, and the current
/// recognition task, and reports what it hears through `onEvent`.
///
/// Continuous feed: `SFSpeechRecognitionTask` ends on its own (final result, timeout, or error)
/// even while the user keeps talking. When that happens while the engine is still running, the
/// service tears the task down and starts a fresh one against the same live audio, so dictation
/// stays continuous. Whatever text the ending task holds - a clean `isFinal` result OR the last
/// partial when it ends on a no-speech/pause error - is emitted as `.finalizedSegment` BEFORE the
/// seam, so the words captured right before a natural pause are committed as a paragraph and never
/// lost to the fresh task's replacing partials. This restart is invisible to the caller.
///
/// Threading: the service's mutable state (`isCapturing`, `task`, `request`) is isolated to the
/// main actor. The audio-tap closure runs on the audio thread but only calls the thread-safe
/// `request.append(buffer)` on a request it captured locally; it never touches isolated state.
/// The recognition-result/completion closure runs on the Speech framework's queue, so it hops to
/// the main actor before reading or mutating state or restarting the task. No shared mutable
/// state is touched off the main actor.
@MainActor
final class SpeechDictationService: SpeechCaptureService {
    /// Called for every event. Set before `start()`.
    var onEvent: ((SpeechCaptureEvent) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer?

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// True between `start()`/`resume()` and `pause()`/`stop()`. Guards the auto-restart so a
    /// task ending after we deliberately stopped does not spin up a new one.
    private var isCapturing = false

    /// Whether to tee the audio to a file for this session (spec 0007). Set via
    /// `setRecordingEnabled` before `start()`. Off by default so a caller that never opts in behaves
    /// exactly as before.
    private var recordingEnabled = false

    /// The tee'd audio writer for the current session, or nil when recording is off or not yet
    /// started. Created ONCE per session (in `start()` when none exists) and kept across recognizer
    /// task restarts AND across pause/resume, so one continuous file spans the whole note. Cleared
    /// (finished) only on `stop()`.
    private var recordingWriter: RecordingWriter?

    /// The recording's absolute time offset at the CURRENT recognition request's start, in seconds.
    /// `SFTranscriptionSegment.timestamp` is relative to its request, and the request restarts many
    /// times per session, so a finalized segment's absolute range is `requestAudioOffset + segment
    /// timestamp`. Captured as the elapsed recording time each time a request begins.
    private var requestAudioOffset: Double = 0

    init(locale: Locale = Locale.current) {
        // Prefer the device locale; fall back to en-US if that locale has no recognizer.
        if let r = SFSpeechRecognizer(locale: locale) {
            self.recognizer = r
        } else {
            self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        }
    }

    // MARK: - Authorization

    /// Request speech + microphone authorization. Returns nil on success, or the first blocking
    /// error otherwise.
    func requestAuthorization() async -> SpeechCaptureError? {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            return .speechNotAuthorized
        }

        let micGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard micGranted else {
            return .microphoneNotAuthorized
        }
        return nil
    }

    /// Whether on-device recognition is possible right now (recognizer exists, is available,
    /// and supports on-device). Returns the blocking error or nil.
    func availabilityError() -> SpeechCaptureError? {
        guard let recognizer else { return .recognizerUnavailable }
        guard recognizer.isAvailable else { return .recognizerUnavailable }
        guard recognizer.supportsOnDeviceRecognition else { return .onDeviceUnavailable }
        return nil
    }

    // MARK: - Recording (spec 0007)

    /// Enable or disable the audio tee for the session `start()` will begin. Set before `start()`.
    func setRecordingEnabled(_ enabled: Bool) {
        recordingEnabled = enabled
    }

    /// The recording written for the session, or nil when nothing was recorded. Only finalized after
    /// `stop()`; the caller adopts the temporary file into storage.
    func recordingURL() -> URL? {
        guard let writer = recordingWriter, writer.hasContent else { return nil }
        return writer.url
    }

    /// Delete the session's recording temp file through the writer (so even a zero-frame file that
    /// `recordingURL()` would not report is removed) and drop the writer, leaving no orphan.
    func discardRecording() {
        recordingWriter?.discard()
        recordingWriter = nil
    }

    // MARK: - Capture lifecycle

    /// Begin capturing. Assumes authorization has already been granted.
    ///
    /// `resume()` routes here too, so the recording writer is created only when one does not already
    /// exist: a pause/resume within the same note keeps appending to the one continuous file, while
    /// a fresh session (after `stop()` cleared it) opens a new one.
    func start() {
        if let error = availabilityError() {
            emit(.failure(error))
            return
        }
        if recordingEnabled && recordingWriter == nil {
            recordingWriter = RecordingWriter()
        }
        do {
            try configureSession()
            isCapturing = true
            try startEngineAndTask()
        } catch {
            isCapturing = false
            emit(.failure(.engineFailure(error.localizedDescription)))
        }
    }

    /// Pause capture, keeping the note. The engine and current task stop; text already
    /// committed to the note is untouched (the note lives in the view model, not here). The
    /// recording writer is NOT finished here - a resume keeps appending to the same file, so one
    /// note maps to one continuous recording.
    func pause() {
        isCapturing = false
        teardownEngineAndTask()
        deactivateSession()
    }

    /// Resume after a pause, starting a fresh task on the same session.
    func resume() {
        start()
    }

    /// Stop capture entirely and release the session. Finishes the recording so its file is complete
    /// and ready for the caller to adopt.
    func stop() {
        isCapturing = false
        teardownEngineAndTask()
        deactivateSession()
        recordingWriter?.finish()
        requestAudioOffset = 0
    }

    // MARK: - Engine + task

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startEngineAndTask() throws {
        guard let recognizer else {
            emit(.failure(.recognizerUnavailable))
            return
        }

        let request = makeRequest()
        self.request = request

        // This request starts at the current recording position, so segment timestamps (which are
        // relative to the request) map to absolute recording time. A resumed session already has
        // frames written; `elapsedSeconds` reflects that, so the offset stays continuous.
        requestAudioOffset = recordingWriter?.elapsedSeconds ?? 0

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Install a single tap that feeds the recognizer, tees to the recording, and drives the
        // waveform level. The tap runs on the audio thread: it appends to the request and writer it
        // captured (both thread-safe) and hops to the main actor only to emit the level. It never
        // reads or mutates the service's isolated state.
        inputNode.removeTap(onBus: 0)
        installTap(on: inputNode, format: format, request: request, writer: recordingWriter)

        self.task = makeTask(with: request, recognizer: recognizer)

        audioEngine.prepare()
        try audioEngine.start()
    }

    /// Build a fresh on-device recognition request.
    private func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        return request
    }

    /// Install the audio tap that feeds `request`, tees the buffer to the recording writer, and
    /// reports the mic level. The request and writer are captured by value so the tap never touches
    /// the service's isolated state; both `SFSpeechAudioBufferRecognitionRequest.append` and
    /// `RecordingWriter.append` are safe to call off the main actor (the writer guards its own
    /// state with a lock). This is the tee: one mic, one tap, buffers forked to two sinks.
    private func installTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest,
        writer: RecordingWriter?
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // Tee to the recording FIRST, then feed recognition. Both appends are thread-safe and
            // touch no isolated service state. Ordering matters for timing: a restart captures the
            // request offset from the writer's frame count, so counting the buffer into the writer
            // before it reaches the recognizer keeps that offset from under-counting at the seam.
            writer?.append(buffer)
            request.append(buffer)
            guard let level = Self.rmsLevel(buffer) else { return }
            Task { @MainActor [weak self] in
                self?.emit(.level(level))
            }
        }
    }

    /// Start a recognition task on `request` whose completion handler hops to the main actor
    /// before touching any isolated state.
    private func makeTask(
        with request: SFSpeechAudioBufferRecognitionRequest,
        recognizer: SFSpeechRecognizer
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { [weak self] result, error in
            // The Speech framework calls this on its own queue; hop to the main actor before
            // reading or mutating state or restarting.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            // Segment timings are relative to THIS request; convert to absolute recording time on
            // the main actor (where `requestAudioOffset` is read). Computed here as request-relative
            // and finalized below.
            let relativeRange = result.map { Self.relativeRange(of: $0.bestTranscription.segments) } ?? nil
            let ended = isFinal || error != nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // COMMIT-ON-END invariant (fixes the "pause clears the transcript" bug): the
                    // recognition task ends not only on a clean `isFinal` result but also on an
                    // ERROR - a natural pause / no-speech timeout / duration limit. In the error
                    // case the last result is a PARTIAL, and the task is about to be replaced by a
                    // fresh one whose new partials would OVERWRITE this text before it was ever
                    // committed - the words spoken right before the pause would vanish. So a task
                    // that is ENDING with any transcription text commits it as a finalized segment
                    // (a paragraph), not a partial. Only a still-running task's mid-phrase update
                    // stays a partial.
                    if ended {
                        // Anchor the request-relative range to the recording. Nil when nothing was
                        // recorded or the recognizer reported no timings (a text-only note path).
                        let range = self.absoluteRange(from: relativeRange)
                        self.emit(.finalizedSegment(text, range: range))
                    } else {
                        self.emit(.partial(text))
                    }
                }
                // A task ends on final result or error. If we are still capturing, this is a
                // duration limit or transient hiccup: restart a fresh task on the same audio so
                // dictation stays continuous.
                if ended {
                    self.restartTaskIfCapturing()
                }
            }
        }
    }

    /// Tear down the finished task and start a new one, keeping the engine and its tap running.
    ///
    /// Ordering matters: we bring up a fresh request and task first, then end audio on the old
    /// request. The tap always has a live request to append to, so no buffers are dropped in a
    /// nil window during the seam.
    private func restartTaskIfCapturing() {
        let oldRequest = request
        let oldTask = task

        guard isCapturing, let recognizer, recognizer.isAvailable else {
            oldRequest?.endAudio()
            oldTask?.cancel()
            task = nil
            request = nil
            return
        }

        // Bring up the replacement before retiring the old one, so the tap never sees nil. The new
        // request starts at the current recording position so its segment timestamps stay anchored
        // to absolute recording time across the seam - the file is continuous, only the request
        // clock resets.
        let newRequest = makeRequest()
        requestAudioOffset = recordingWriter?.elapsedSeconds ?? 0
        let newInputNode = audioEngine.inputNode
        let format = newInputNode.outputFormat(forBus: 0)
        newInputNode.removeTap(onBus: 0)
        installTap(on: newInputNode, format: format, request: newRequest, writer: recordingWriter)

        request = newRequest
        task = makeTask(with: newRequest, recognizer: recognizer)

        // Now retire the old request/task; the tap is already feeding the new request.
        oldRequest?.endAudio()
        oldTask?.cancel()
    }

    private func teardownEngineAndTask() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    // MARK: - Helpers

    private func emit(_ event: SpeechCaptureEvent) {
        onEvent?(event)
    }

    /// The request-relative range spanned by a transcription's segments, or nil when there are none.
    /// Pulls the raw `timestamp`/`duration` off the first/last segments and delegates the math to the
    /// testable `RecordingTiming` (segments have no public initializer, so the numbers are extracted
    /// here and the logic lives where it can be unit-tested).
    ///
    /// Nonisolated: called on the Speech framework's queue before hopping to the main actor. It only
    /// reads the passed-in segments and touches no service state.
    nonisolated static func relativeRange(of segments: [SFTranscriptionSegment]) -> (start: Double, duration: Double)? {
        guard let first = segments.first, let last = segments.last else { return nil }
        return RecordingTiming.relativeRange(
            firstStart: first.timestamp,
            lastStart: last.timestamp,
            lastDuration: last.duration
        )
    }

    /// Anchor a request-relative range to the recording by adding the offset captured when this
    /// request began. Returns nil when there is no recording (recording disabled) or no relative
    /// range, so a text-only session emits a nil range and behaves exactly as before.
    private func absoluteRange(from relative: (start: Double, duration: Double)?) -> ParagraphTiming? {
        guard recordingWriter != nil else { return nil }
        return RecordingTiming.absolute(offset: requestAudioOffset, relative: relative)
    }

    /// Root-mean-square level of a buffer, normalized to a rough 0...1 for the waveform.
    nonisolated static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let channel = channelData[0]
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }

        var sum: Float = 0
        for i in 0..<frames {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frames))
        guard rms.isFinite else { return 0 }
        return normalizedLevel(fromRMS: rms)
    }

    /// Map a raw RMS amplitude (0...1 float PCM) to a 0...1 waveform level. Split out from
    /// `rmsLevel` so the mapping is unit-testable without an audio buffer.
    ///
    /// Feedback 0005: the old `rms * 12` left the bars pinned at the floor for normal speaking - a
    /// float-PCM RMS for conversational speech is roughly 0.02...0.08, so `* 12` capped at ~0.24...1
    /// but hovered near the low end, and the view model's smoothing pulled it down further. A square
    /// root (perceptual) curve with a higher gain lifts normal speech well clear of the floor while
    /// still saturating loud input, so the bars visibly ride the voice.
    nonisolated static func normalizedLevel(fromRMS rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        // sqrt gives a perceptual response (quiet speech is not crushed); the gain sets where normal
        // speaking lands. Tuned so ordinary speech (~0.03...0.06 RMS) maps to ~0.4...0.7.
        let shaped = sqrt(rms) * 2.6
        return min(1, max(0, shaped))
    }
}
