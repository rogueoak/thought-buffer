import Foundation
@preconcurrency import AVFoundation
import Speech

/// Transcribes a finished audio FILE into `[TranscribedSegment]` on the phone (spec 0023), the NEW
/// file-based analogue of the live-capture `SpeechAnalyzerService`. A watch recording arrives as a
/// complete `.m4a`; there is no live mic and no analysis restart, so this runs the iOS 26
/// `SpeechAnalyzer` over the whole file in one pass (`analyzeSequence(from:)`) and collects every
/// finalized result's text + time range. The pure grouping into paragraphs + timings then happens in
/// `FileTranscriptionMapper` - this class is only the thin, device-verified decode of the recognizer's
/// output into plain segments.
///
/// It sits behind the `FileTranscribing` seam so `WatchCaptureIngestService` can be unit-tested with a
/// stub transcriber (returning fixed segments, or throwing to prove the audio-only fallback) without a
/// real recognizer or an audio file.
protocol FileTranscribing: Sendable {
    /// Transcribe the audio file at `url` into ordered segments (text + file-relative time ranges).
    /// Throws on a recognizer/model failure; the caller treats any throw (or an empty result) as the
    /// audio-only fallback so the capture is never dropped.
    func transcribe(fileAt url: URL) async throws -> [TranscribedSegment]
}

/// Errors the file transcriber can surface. The ingest path treats ALL of them as "file it audio-only"
/// (the recording is kept), so these are for logging/testing intent, not user copy.
enum FileTranscriptionError: Error, Equatable {
    case recognizerUnavailable
    case modelUnavailable
    case unreadableFile
}

/// Production `FileTranscribing` over `SpeechAnalyzer` + `SpeechTranscriber` (spec 0023). On-device
/// only, like the live path: the same model install, the same locale resolution, no audio leaves the
/// phone. Runs `analyzeSequence(from:)` over the file and reads each finalized result's `CMTimeRange`
/// (file-relative, so no offset anchoring is needed - a file has one continuous timeline).
final class SpeechAnalyzerFileTranscriber: FileTranscribing {
    func transcribe(fileAt url: URL) async throws -> [TranscribedSegment] {
        guard SpeechTranscriber.isAvailable else { throw FileTranscriptionError.recognizerUnavailable }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw FileTranscriptionError.unreadableFile
        }

        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
            ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        // Make sure the on-device model is installed (a one-time download or a no-op); a failure means
        // we cannot transcribe, so the caller files the capture audio-only.
        try await ensureModelInstalled(transcriber)

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Collect finalized results while the file is analyzed. `analyzeSequence(from:)` drives the whole
        // file through in one pass and returns when the audio is exhausted; the results stream then
        // finishes after a finalize. Volatile results are not requested, so every result is final.
        let collector = Task { () -> [TranscribedSegment] in
            var segments: [TranscribedSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let start = result.range.start.seconds
                let duration = result.range.duration.seconds
                segments.append(TranscribedSegment(
                    text: text,
                    startSeconds: start.isFinite ? start : 0,
                    durationSeconds: duration.isFinite ? duration : 0
                ))
            }
            return segments
        }

        _ = try await analyzer.analyzeSequence(from: audioFile)
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        return try await collector.value
    }

    /// Ensure the transcriber's on-device model is installed, mapping a missing/unsupported model to a
    /// throw so the caller falls back to audio-only.
    private func ensureModelInstalled(_ transcriber: SpeechTranscriber) async throws {
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return
        case .unsupported:
            throw FileTranscriptionError.modelUnavailable
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        @unknown default:
            throw FileTranscriptionError.modelUnavailable
        }
    }
}
