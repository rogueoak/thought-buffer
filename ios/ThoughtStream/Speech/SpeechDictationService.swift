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
final class SpeechDictationService {
    /// Events the service reports back to its consumer, always on the main actor.
    enum Event {
        /// The in-progress phrase for the current task (replaces the last partial).
        case partial(String)
        /// A finalized phrase that should be committed to the note as a paragraph.
        case finalizedSegment(String)
        /// Microphone input level, 0...1, for the waveform.
        case level(Float)
        /// A user-facing failure. Capture has stopped.
        case failure(DictationError)
    }

    /// Reasons capture cannot proceed, each mapped to friendly copy in the UI.
    enum DictationError: Equatable {
        case speechNotAuthorized
        case microphoneNotAuthorized
        case onDeviceUnavailable
        case recognizerUnavailable
        case engineFailure(String)
    }

    /// Called for every event. Set before `start()`.
    var onEvent: (@MainActor (Event) -> Void)?

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
    func requestAuthorization() async -> DictationError? {
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
    func availabilityError() -> DictationError? {
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

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Install a single tap that both feeds the recognizer and drives the waveform level.
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
            if let level = Self.rmsLevel(buffer) {
                self?.emit(.level(level))
            }
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    self.emit(.finalizedSegment(text))
                } else {
                    self.emit(.partial(text))
                }
            }

            // A task ends on final result or error. If we are still capturing, this is a
            // duration limit or transient hiccup: restart a fresh task on the same audio so
            // dictation stays continuous.
            let ended = (result?.isFinal ?? false) || error != nil
            if ended {
                self.restartTaskIfCapturing()
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    /// Tear down the finished task and start a new one, keeping the engine and its tap running.
    private func restartTaskIfCapturing() {
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil

        guard isCapturing else { return }

        guard let recognizer, recognizer.isAvailable else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    self.emit(.finalizedSegment(text))
                } else {
                    self.emit(.partial(text))
                }
            }
            let ended = (result?.isFinal ?? false) || error != nil
            if ended {
                self.restartTaskIfCapturing()
            }
        }
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

    private func emit(_ event: Event) {
        let handler = onEvent
        Task { @MainActor in handler?(event) }
    }

    /// Root-mean-square level of a buffer, normalized to a rough 0...1 for the waveform.
    static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float? {
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
