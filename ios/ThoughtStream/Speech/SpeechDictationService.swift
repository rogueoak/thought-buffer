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

    /// The latest partial (in-progress transcription) text for the CURRENT task. On a real device a
    /// task can END with an ERROR and a NIL result - no final transcription at all - while text is
    /// still held only as this in-progress partial. Without tracking it, that text would be lost when
    /// the fresh task's replacing partials overwrite the view model's `partial` (feedback 0006).
    /// Reset to empty when a new task starts (`startEngineAndTask`) and after committing at a task
    /// end, so it never double-commits or leaks across the seam.
    private var lastPartialText = ""

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
        // Clear the tracked partial BEFORE tearing down: cancelling the task can deliver a late
        // nil-result end callback after the note is already saved, and `resolveEnd(nil, lastPartial)`
        // would otherwise fall back to that partial and emit a SECOND `.finalizedSegment`, doubling
        // the live paragraph. Emptying it here makes that late end commit nothing.
        lastPartialText = ""
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

        // A fresh task tracks its own in-progress partial from scratch: any text held by a prior
        // task was already committed at its end (see `makeTask`), so start empty to avoid double
        // commits.
        lastPartialText = ""

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
                if ended {
                    // Anchor the request-relative range to the recording, but only when the RESULT
                    // itself carried text (a nil-result end has no range to derive - `resolveEnd`
                    // decides which text is committed).
                    let range = self.absoluteRange(from: relativeRange)
                    self.handleTaskEnd(resultText: text, resultRange: range)
                } else {
                    self.handlePartial(text)
                }
            }
        }
    }

    /// A still-running task reported a mid-phrase update. Track it as the latest partial (so a later
    /// error+nil end can still commit it) and show it live. Empty/whitespace text is ignored.
    private func handlePartial(_ resultText: String?) {
        guard let resultText,
              !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // On-device utterance RESET (feedback 0007): after a pause the recognizer sometimes begins a
        // NEW utterance's transcription within the SAME task instead of extending the previous one, and
        // never fires a task end - so the words before the pause live only in `lastPartialText` and the
        // new partial would overwrite them, losing them. When the new partial is NOT a continuation of
        // the last one, commit the previous partial as its own paragraph BEFORE adopting the new text.
        if Self.isReset(previous: lastPartialText, current: resultText) {
            emit(.finalizedSegment(lastPartialText, range: nil))
        }
        lastPartialText = resultText
        emit(.partial(resultText))
    }

    /// True when `current` is a NEW utterance rather than a continuation/revision of `previous` - i.e.
    /// the on-device recognizer reset its transcription within a task.
    ///
    /// The recognizer REVISES earlier words as it gains context ("it" -> "it's", "there is" ->
    /// "there's"), so a word-exact prefix comparison spuriously fires on every revision and re-commits
    /// growing prefixes of the SAME sentence (the duplicate-paragraph bug). Instead compare how much of
    /// the PREVIOUS text `current` still reproduces at its start: a continuation keeps most of it (even
    /// with revisions and extensions), while a genuinely new sentence shares little or none of it. Uses
    /// the character-level common prefix so small word edits do not count as a reset. Pure and
    /// nonisolated, so it is unit-testable off the main actor.
    nonisolated static func isReset(previous: String, current: String) -> Bool {
        let prev = previous.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let curr = current.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !prev.isEmpty else { return false }
        let common = zip(prev, curr).prefix { $0.0 == $0.1 }.count
        // A reset keeps less than ~60% of the previous text at the new text's start.
        return Double(common) < Double(prev.count) * 0.6
    }

    /// A task ENDED (clean final OR error). Commit the best available text as a finalized segment,
    /// reset the tracked partial, and restart if still capturing. Split out (and the text decision
    /// delegated to the pure `resolveEnd`) so the accumulating-segment + nil-result-end behavior is
    /// unit-testable without a live mic.
    private func handleTaskEnd(resultText: String?, resultRange: ParagraphTiming?) {
        switch Self.resolveEnd(resultText: resultText, lastPartial: lastPartialText) {
        case .usedResult(let text):
            // The result carried the committed text, so its timings are valid; keep the range.
            emit(.finalizedSegment(text, range: resultRange))
        case .usedPartial(let text):
            // A partial committed from a nil-result end has no result timings, so emit a nil range.
            emit(.finalizedSegment(text, range: nil))
        case .none:
            break
        }
        // Committed (or nothing to commit): clear the tracked partial so a restart never re-commits it.
        lastPartialText = ""
        // If still capturing, this is a duration limit or transient hiccup: restart a fresh task on
        // the same audio so dictation stays continuous.
        restartTaskIfCapturing()
    }

    /// COMMIT-ON-END invariant (feedback 0005 + 0006). Given the ending task's `resultText` (nil when
    /// the task ended with an error and NO final transcription) and the `lastPartial` it had been
    /// accumulating, return the text to commit as a paragraph, or nil when there is nothing usable.
    ///
    /// On a real device a task ACCUMULATES the whole passage into one growing transcription and
    /// finalizes only when it ends. An error end can arrive with a nil result, leaving the words held
    /// ONLY as the in-progress partial - which the fresh task's partials would overwrite if it were
    /// not committed here. So commit the result's transcription when it is non-empty, otherwise the
    /// last partial. A clean final already CONTAINS the partial, so this uses it ONCE (never also the
    /// partial) - no double commit - and never returns empty/whitespace text.
    ///
    /// Pure and static (nonisolated: no service state touched), so it is fully unit-testable off the
    /// main actor. Returns which source was committed, so the caller decides whether a range applies
    /// (only `.usedResult` carries valid result timings) WITHOUT re-deriving it from the raw inputs.
    nonisolated static func resolveEnd(resultText: String?, lastPartial: String) -> EndCommit {
        // Trim only to DECIDE which source is usable; the returned string is the UNTRIMMED original,
        // so the committed paragraph preserves the user's exact leading/trailing whitespace (the
        // view model's `commitParagraph` does the final trim before it lands in the note).
        let trimmedResult = resultText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedResult.isEmpty, let resultText {
            // A clean/non-empty result supersedes the partial (it already contains it).
            return .usedResult(resultText)
        }
        let trimmedPartial = lastPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPartial.isEmpty ? .none : .usedPartial(lastPartial)
    }

    /// Which text source `resolveEnd` chose to commit at a task end, so `handleTaskEnd` can attach a
    /// range only when the RESULT (which carries the timings) was used, without re-inspecting inputs.
    enum EndCommit: Equatable {
        /// Commit the task's result transcription; its recording range is valid.
        case usedResult(String)
        /// Commit the tracked partial (nil-result end); no result timings, so no range.
        case usedPartial(String)
        /// Nothing usable to commit (neither a result nor a partial).
        case none
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
        // The finite/non-negative guard lives in `normalizedLevel(fromRMS:)` (single source of
        // truth), so a NaN/inf RMS maps to 0 there without a duplicate guard here.
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
