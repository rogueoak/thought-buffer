import Foundation
import AVFoundation

/// The seam a caller uses to JOIN a newly-recorded segment onto a thought's existing recording when a
/// thought that already has audio is resumed with recording on (feedback 0022). A protocol so the view
/// model is testable with a stub and so the AVFoundation glue stays thin and swappable, exactly like
/// `AudioTrimming`.
protocol AudioConcatenating: Sendable {
    /// Read the `existing` `.m4a` and the `new` segment `.m4a` and PRODUCE a combined copy at a temp URL
    /// containing the existing audio followed by the new segment - WITHOUT touching either input. Runs
    /// off the main actor. The temp file is verified to be a valid non-empty audio file before it is
    /// returned, so the caller can safely adopt it (the caller, which owns the store, performs the actual
    /// COORDINATED atomic replace of the original through `replaceAudio`, because on iCloud the swap must
    /// go through `NSFileCoordinator`, so the concatenator deliberately does not replace the file itself).
    ///
    /// On ANY failure (an unreadable input, a format the two files cannot be joined in, a write / verify
    /// error) returns `.notConcatenated` and writes nothing, so the caller falls back to keeping the
    /// original recording untouched and appending the new paragraphs as text-only - exactly the pre-0022
    /// behavior. Never throws: a concatenation is best-effort and must never lose the original recording.
    func concatenate(existing: URL, new: URL) async -> AudioConcatenationResult
}

/// The outcome of a concatenation attempt.
enum AudioConcatenationResult: Equatable {
    /// A verified combined copy was written to `combinedFileURL` (a temp file the caller must adopt or
    /// clean up); `existingDuration` is the seconds the EXISTING recording occupies at the front of the
    /// join, used to offset the newly-recorded paragraphs' timings onto the combined timeline. Neither
    /// input file is touched - the caller swaps the combined file in through the store's coordinated seam.
    case concatenated(combinedFileURL: URL, existingDuration: Double)
    /// No combined file was produced (an unreadable input, an incompatible format, or a safe failure
    /// fallback). Both input files are untouched; the caller keeps the original recording as-is.
    case notConcatenated
}

/// Reads a thought's existing `.m4a` plus a freshly-recorded segment `.m4a` and writes a single combined
/// AAC file (existing audio, then the new segment) to a temp URL, verifying it is a valid non-empty audio
/// file. It never touches either input: the caller adopts the verified temp through the store's
/// coordinated atomic-replace seam (`replaceAudio`), because on iCloud the swap must be coordinated. Any
/// failure returns `.notConcatenated` and writes nothing, so the caller keeps the original recording.
///
/// All AVFoundation work happens here so `RecordingTiming.offsetResumedTimings` (the timing math) stays
/// pure. The type is `Sendable` and its one method is designed to run inside a detached task off the main
/// actor. The frame read/write plumbing mirrors `AudioTrimmer` (chunked copy, protected temp, defer
/// cleanup, output validation) so raw voice is never orphaned unprotected on a mid-write failure.
struct AudioConcatenator: AudioConcatenating {
    /// The output-validity check run on the combined temp file before it is returned to the caller.
    /// Injectable so a test can force it to fail and exercise the SAFETY branch (the temp is discarded and
    /// `.notConcatenated` returned, leaving the original intact). Defaults to the real check.
    private let validateOutput: (@Sendable (URL) -> Bool)?

    init(validateOutput: (@Sendable (URL) -> Bool)? = nil) {
        self.validateOutput = validateOutput
    }

    func concatenate(existing: URL, new: URL) async -> AudioConcatenationResult {
        do {
            return try performConcatenation(existing: existing, new: new)
        } catch {
            // Any failure (read, format mismatch, write, verify) leaves BOTH inputs untouched. The
            // original recording is never lost for the sake of a concatenation - the caller falls back to
            // keeping it and appending the new paragraphs as text-only.
            return .notConcatenated
        }
    }

    /// The concatenation body, factored so the outer `concatenate` can swallow every failure into
    /// `.notConcatenated`.
    private func performConcatenation(existing: URL, new: URL) throws -> AudioConcatenationResult {
        let existingFile = try AVAudioFile(forReading: existing)
        let existingFormat = existingFile.processingFormat
        let sampleRate = existingFormat.sampleRate
        guard sampleRate > 0, existingFile.length > 0 else { return .notConcatenated }
        let existingDuration = Double(existingFile.length) / sampleRate

        let newFile = try AVAudioFile(forReading: new)
        // An empty new segment (the user resumed but said nothing) must not corrupt the existing
        // recording: with nothing to append, there is nothing to concatenate, so bail without producing
        // a file. The caller keeps the original recording unchanged and appends any text as text-only.
        guard newFile.length > 0 else { return .notConcatenated }
        // Both segments were captured by the same on-device pipeline, so their formats match in practice;
        // guard anyway so a mismatched pair falls back safely rather than writing a garbled file.
        guard newFile.processingFormat.sampleRate == sampleRate,
              newFile.processingFormat.channelCount == existingFormat.channelCount else {
            return .notConcatenated
        }

        let tempURL = try writeCombined(existing: existingFile, new: newFile, format: existingFormat)

        // Verify the output is a real, non-empty audio file before handing it to the caller to adopt. On a
        // verify failure the temp is discarded and both inputs stay exactly as they were.
        let isValid = (validateOutput ?? { self.isValidNonEmptyAudio(at: $0) })(tempURL)
        guard isValid else {
            try? FileManager.default.removeItem(at: tempURL)
            return .notConcatenated
        }
        return .concatenated(combinedFileURL: tempURL, existingDuration: existingDuration)
    }

    /// Write a combined `.m4a` to a temp URL: the whole of `existing` followed by the whole of `new`, by
    /// READING each source `AVAudioFile` in chunks and WRITING into a fresh AAC file. Deterministic and
    /// self-contained (no `AVAsset` track loading or `AVAssetExportSession`, which are async / load-gated
    /// on modern iOS), so the join is a straight-line off-main read/write, matching `AudioTrimmer`.
    private func writeCombined(existing: AVAudioFile, new: AVAudioFile, format: AVAudioFormat) throws -> URL {
        let fm = FileManager.default
        let tempURL = fm.temporaryDirectory
            .appendingPathComponent("thoughtstream-concat-\(UUID().uuidString).\(ThoughtStore.audioFileExtension)")
        try? fm.removeItem(at: tempURL)

        // Create the temp file PROTECTED (`completeUnlessOpen`) before `AVAudioFile` writes any audio into
        // it, mirroring `RecordingWriter` / `AudioTrimmer`: raw audio is sensitive, so there must be no
        // window where the combined `.m4a` exists on disk unprotected.
        fm.createFile(
            atPath: tempURL.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
        )

        // Remove the partial temp on EVERY early/error exit so a mid-write failure never orphans a partial
        // copy of raw voice in the shared temp dir. Only a clean success clears the flag and keeps the file.
        var succeeded = false
        defer { if !succeeded { try? fm.removeItem(at: tempURL) } }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let output = try AVAudioFile(forWriting: tempURL, settings: settings)

        try copyAll(from: existing, to: output, format: format)
        try copyAll(from: new, to: output, format: format)

        succeeded = true
        return tempURL
    }

    /// Copy the whole of `source` to `output`, chunked so a long recording does not need one huge buffer.
    private func copyAll(from source: AVAudioFile, to output: AVAudioFile, format: AVAudioFormat) throws {
        let chunkFrames = AVAudioFrameCount(max(1, Int(format.sampleRate))) // ~1s per read
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw ConcatError.bufferAllocationFailed
        }
        source.framePosition = 0
        var remaining = source.length
        while remaining > 0 {
            let toRead = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), remaining))
            try source.read(into: buffer, frameCount: toRead)
            let read = buffer.frameLength
            if read == 0 { break }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(read)
        }
    }

    /// Whether the file at `url` is a real, non-empty, readable audio file. Guards the caller's adopt:
    /// the original is never replaced unless the combined output has bytes AND opens with frames.
    func isValidNonEmptyAudio(at url: URL) -> Bool {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
        guard size > 0 else { return false }
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0
    }

    private enum ConcatError: Error {
        case bufferAllocationFailed
    }
}
