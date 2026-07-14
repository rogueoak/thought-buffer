import Foundation
// @preconcurrency: the audio-tap and converter blocks are @Sendable and capture AVAudioPCMBuffer
// (not Sendable), but they run synchronously on the audio thread and never cross an actor boundary,
// so the Sendable warnings are noise. Suppress them at the import.
@preconcurrency import AVFoundation
import Speech

/// On-device speech-to-text capture built on the iOS 26 `SpeechAnalyzer` + `SpeechTranscriber` API
/// (spec 0009). Owns the audio engine, the analyzer, and the transcriber, and reports what it hears
/// through `onEvent`.
///
/// Why this replaces the old `SFSpeechRecognizer` service: the transcriber reports VOLATILE
/// (in-progress) and FINALIZED (stable, immutable) results explicitly. A volatile result drives the
/// live caret; a finalized result is a committed paragraph with a precise audio `CMTimeRange`. That
/// removes every utterance-boundary heuristic the old API forced on us (reset detection, task-end
/// dedup, restart-to-continue) - the recognizer now tells us where a paragraph ends instead of us
/// guessing from a noisy accumulating stream.
///
/// Threading: `@MainActor`-isolated state. The audio-tap closure runs on the audio thread and only
/// touches the thread-safe recording writer, the (audio-thread-serial) format converter, and the
/// `AsyncStream` continuation; it hops to the main actor only to emit the level. Transcriber results
/// are consumed in a task that hops to the main actor before emitting.
@MainActor
final class SpeechAnalyzerService: SpeechCaptureService {
    var onEvent: ((SpeechCaptureEvent) -> Void)?

    private let audioEngine = AVAudioEngine()

    /// Built per session in `beginAnalysis`. The analyzer is an actor; the transcriber is Sendable, so
    /// its `results` sequence is consumed from a task.
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?

    /// Feeds converted mic buffers to the analyzer. Finished on pause/stop so the analyzer knows input
    /// ended and can flush its final results.
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    /// Consumes `transcriber.results`, mapping volatile -> `.partial` and final -> `.finalizedSegment`.
    private var resultsTask: Task<Void, Never>?
    /// The async session bring-up, cancellable if the user stops before it finishes.
    private var startTask: Task<Void, Never>?

    /// The locale resolved to one the transcriber supports (set during authorization).
    private var resolvedLocale = Locale.current

    private var isCapturing = false

    /// Whether to tee audio to a file for this session (spec 0007). Same behavior as before.
    private var recordingEnabled = false
    private var recordingWriter: RecordingWriter?

    /// The recording seconds elapsed when the current analysis began. A finalized result's
    /// `CMTimeRange` is relative to the analysis start, and analysis restarts on resume while the
    /// recording file is continuous, so this offset anchors a paragraph's range to absolute recording
    /// time (same role as the old request offset).
    private var analyzerAudioOffset: Double = 0

    // MARK: - Authorization

    func requestAuthorization() async -> SpeechCaptureError? {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { return .speechNotAuthorized }

        let micGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard micGranted else { return .microphoneNotAuthorized }

        // Ensure the on-device language model is installed. This is a one-time model download (or a
        // no-op when already installed); transcription itself is fully on-device and no audio ever
        // leaves the phone.
        return await ensureModelInstalled()
    }

    /// Resolve a supported locale and make sure its transcriber assets are installed, mapping the
    /// outcome to a blocking `SpeechCaptureError` or nil on success.
    private func ensureModelInstalled() async -> SpeechCaptureError? {
        guard SpeechTranscriber.isAvailable else { return .recognizerUnavailable }
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
            ?? Locale(identifier: "en-US")
        resolvedLocale = locale
        let probe = makeTranscriber(locale: locale)
        switch await AssetInventory.status(forModules: [probe]) {
        case .installed:
            return nil
        case .unsupported:
            return .onDeviceUnavailable
        case .supported, .downloading:
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                    try await request.downloadAndInstall()
                }
                return nil
            } catch {
                return .onDeviceUnavailable
            }
        @unknown default:
            return .onDeviceUnavailable
        }
    }

    func availabilityError() -> SpeechCaptureError? {
        SpeechTranscriber.isAvailable ? nil : .recognizerUnavailable
    }

    // MARK: - Recording (spec 0007)

    func setRecordingEnabled(_ enabled: Bool) {
        recordingEnabled = enabled
    }

    func recordingURL() -> URL? {
        guard let writer = recordingWriter, writer.hasContent else { return nil }
        return writer.url
    }

    func discardRecording() {
        recordingWriter?.discard()
        recordingWriter = nil
    }

    // MARK: - Capture lifecycle

    func start() {
        if let error = availabilityError() {
            emit(.failure(error))
            return
        }
        if recordingEnabled && recordingWriter == nil {
            recordingWriter = RecordingWriter()
        }
        isCapturing = true
        // Bring the session up asynchronously (the analyzer format and start are async); a failure
        // surfaces as a `.failure` event, mirroring the old engine-failure path.
        startTask = Task { [weak self] in
            await self?.beginAnalysis()
        }
    }

    /// Stand up the transcriber, analyzer, input stream, results consumer, mic tap, and engine.
    private func beginAnalysis() async {
        do {
            try configureSession()

            let transcriber = makeTranscriber(locale: resolvedLocale)
            self.transcriber = transcriber

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer

            // The format the analyzer wants; the mic tap is converted into it.
            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

            guard isCapturing else { return } // stopped during async bring-up

            let (stream, continuation) = AsyncStream.makeStream(
                of: AnalyzerInput.self, bufferingPolicy: .unbounded)
            inputContinuation = continuation

            // This analysis starts at the current recording position, so finalized-result time ranges
            // map to absolute recording time across a pause/resume seam.
            analyzerAudioOffset = recordingWriter?.elapsedSeconds ?? 0

            // Consume results (transcriber is Sendable). Volatile -> partial, final -> paragraph.
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        await self?.handle(result: result)
                    }
                } catch {
                    await self?.handleResultsFailure(error)
                }
            }

            installTap(analyzerFormat: analyzerFormat, continuation: continuation, writer: recordingWriter)

            audioEngine.prepare()
            try audioEngine.start()
            try await analyzer.start(inputSequence: stream)
        } catch {
            isCapturing = false
            emit(.failure(.engineFailure(error.localizedDescription)))
        }
    }

    func pause() {
        isCapturing = false
        // Finalize so the in-progress utterance is committed (with its timing) before teardown, then
        // release the session. Async because finalizing flushes the last results through the consumer.
        Task { [weak self] in
            await self?.finishAnalysis(deactivate: true)
        }
    }

    func resume() {
        start()
    }

    func stop() {
        isCapturing = false
        // Stop emitting immediately: the view model folds the last live partial into the note on
        // finish, so no words are lost, and cancelling here means no late finalized result lands after
        // the note is already saved (which would append a duplicate paragraph).
        resultsTask?.cancel()
        resultsTask = nil
        startTask?.cancel()
        startTask = nil
        teardownEngine()
        inputContinuation?.finish()
        inputContinuation = nil
        analyzer = nil
        transcriber = nil
        deactivateSession()
        recordingWriter?.finish()
        analyzerAudioOffset = 0
    }

    /// Tear the engine and analyzer down, finalizing so any last finalized result is flushed through
    /// the results consumer first (used by pause, where the in-progress utterance should commit).
    private func finishAnalysis(deactivate: Bool) async {
        startTask?.cancel()
        startTask = nil
        teardownEngine()
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        await resultsTask?.value // let the final results drain into paragraphs
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        if deactivate { deactivateSession() }
    }

    // MARK: - Engine + tap

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func teardownEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    /// A fresh transcriber for `locale`, configured to report volatile results and per-result audio
    /// time ranges. One place builds it so the probe (asset check) and the live one match.
    private func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// Install the mic tap: tee each buffer to the recording writer, report the level, and convert the
    /// buffer into the analyzer's format before yielding it as analyzer input. One mic, three sinks,
    /// as before - only the recognizer sink changed.
    private func installTap(
        analyzerFormat: AVAudioFormat?,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        writer: RecordingWriter?
    ) {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let converter = analyzerFormat.flatMap { AVAudioConverter(from: inputFormat, to: $0) }
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            // Tee to the recording first (unchanged), then feed recognition.
            writer?.append(buffer)
            if let level = Self.rmsLevel(buffer) {
                Task { @MainActor [weak self] in self?.emit(.level(level)) }
            }
            // Convert to the analyzer format (resampling if needed). When there is no converter
            // (formats already match, or none reported), forward the raw buffer.
            if let converter, let format = analyzerFormat {
                if let converted = Self.convert(buffer, using: converter, to: format) {
                    continuation.yield(AnalyzerInput(buffer: converted))
                }
            } else {
                continuation.yield(AnalyzerInput(buffer: buffer))
            }
        }
    }

    // MARK: - Results

    /// Map one transcriber result to a capture event: a finalized result is a committed paragraph with
    /// its recording range; a volatile result is the live partial.
    private func handle(result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if result.isFinal {
            emit(.finalizedSegment(text, range: paragraphTiming(for: result.range)))
        } else {
            emit(.partial(text))
        }
    }

    /// Map a finalized result's audio `CMTimeRange` to a `ParagraphTiming` in absolute recording time,
    /// or nil when nothing was recorded (transcript-only) or the range is empty, so a text-only session
    /// behaves exactly as before.
    private func paragraphTiming(for range: CMTimeRange) -> ParagraphTiming? {
        guard recordingWriter != nil else { return nil }
        let start = range.start.seconds
        let duration = range.duration.seconds
        guard start.isFinite, duration.isFinite, duration > 0 else { return nil }
        return RecordingTiming.absolute(
            offset: analyzerAudioOffset, relative: (start: start, duration: duration))
    }

    private func handleResultsFailure(_ error: Error) {
        guard isCapturing else { return } // a cancel during teardown is not a user-facing failure
        emit(.failure(.engineFailure(error.localizedDescription)))
    }

    // MARK: - Helpers

    private func emit(_ event: SpeechCaptureEvent) {
        onEvent?(event)
    }

    /// Convert a tap buffer into `format` (resampling as needed) so it can feed the analyzer. Pure and
    /// nonisolated: called on the audio thread, touching only its arguments.
    nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard capacity > 0, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// Root-mean-square level of a buffer, normalized to a rough 0...1 for the waveform. Unchanged
    /// from the previous service so the waveform behaves identically.
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
        return normalizedLevel(fromRMS: rms)
    }

    /// Map a raw RMS amplitude (0...1 float PCM) to a 0...1 waveform level (perceptual sqrt curve,
    /// tuned gain). Unchanged from the previous service; unit-tested.
    nonisolated static func normalizedLevel(fromRMS rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let shaped = sqrt(rms) * 2.6
        return min(1, max(0, shaped))
    }
}
