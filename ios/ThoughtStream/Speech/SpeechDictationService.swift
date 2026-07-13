import Foundation
import AVFoundation
import Speech

/// On-device speech-to-text capture. Owns the audio engine, the recognizer, and the current
/// recognition task, and reports what it hears through `onEvent`.
///
/// Continuous feed: `SFSpeechRecognitionTask` ends on its own (final result, timeout, or error)
/// even while the user keeps talking. When that happens while the engine is still running, the
/// service tears the task down and starts a fresh one against the same live audio, so dictation
/// stays continuous. Each finalized segment is emitted as `.finalizedSegment` before the seam,
/// so no committed text is lost. This restart is invisible to the caller.
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

    // MARK: - Capture lifecycle

    /// Begin capturing. Assumes authorization has already been granted.
    func start() {
        if let error = availabilityError() {
            emit(.failure(error))
            return
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
    /// committed to the note is untouched (the note lives in the view model, not here).
    func pause() {
        isCapturing = false
        teardownEngineAndTask()
        deactivateSession()
    }

    /// Resume after a pause, starting a fresh task on the same session.
    func resume() {
        start()
    }

    /// Stop capture entirely and release the session.
    func stop() {
        isCapturing = false
        teardownEngineAndTask()
        deactivateSession()
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

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Install a single tap that both feeds the recognizer and drives the waveform level.
        // The tap runs on the audio thread: it appends to the request it captured (that API is
        // thread-safe) and hops to the main actor only to emit the level. It never reads or
        // mutates the service's isolated state.
        inputNode.removeTap(onBus: 0)
        installTap(on: inputNode, format: format, request: request)

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

    /// Install the audio tap that feeds `request` and reports the mic level. The request is
    /// captured by value so the tap never touches the service's isolated `request` property.
    private func installTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // `append` is thread-safe and does not touch isolated state.
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
            let ended = isFinal || error != nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let text {
                    if isFinal {
                        self.emit(.finalizedSegment(text))
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

        // Bring up the replacement before retiring the old one, so the tap never sees nil.
        let newRequest = makeRequest()
        let newInputNode = audioEngine.inputNode
        let format = newInputNode.outputFormat(forBus: 0)
        newInputNode.removeTap(onBus: 0)
        installTap(on: newInputNode, format: format, request: newRequest)

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

        // Map RMS to 0...1 with a gentle curve so quiet speech still moves the bars.
        let normalized = min(1, max(0, rms * 12))
        return normalized
    }
}
