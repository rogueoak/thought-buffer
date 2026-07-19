import Foundation
import AVFoundation

/// The seam a caller uses to trim dead air from a finished recording (spec 0019). A protocol so the
/// view model is testable with a stub and so the AVFoundation glue stays thin and swappable.
protocol AudioTrimming: Sendable {
    /// Analyze the `.m4a` at `url` and, if it has trimmable silence, PRODUCE a trimmed copy at a temp
    /// URL - WITHOUT touching the original. Runs off the main actor. The temp file is verified to be a
    /// valid non-empty audio file before it is returned, so the caller can safely adopt it (the caller,
    /// which owns the store, performs the actual COORDINATED atomic replace of the original - the trim
    /// is non-reversible and, on iCloud, the swap must go through `NSFileCoordinator`, so the trimmer
    /// deliberately does not replace the file itself). On ANY failure (unreadable, nothing to trim, a
    /// write / verify error) returns `.notTrimmed` and writes nothing. Never throws: a trim is
    /// best-effort and must never lose the recording.
    func trim(fileAt url: URL) async -> AudioTrimResult
}

/// The outcome of a trim attempt.
enum AudioTrimResult: Equatable {
    /// A verified trimmed copy was written to `trimmedFileURL` (a temp file the caller must adopt or
    /// clean up); `removedRanges` are the removed original-timeline seconds for the timing remap. The
    /// ORIGINAL file is untouched - the caller swaps it in through the store's coordinated seam.
    case trimmed(trimmedFileURL: URL, removedRanges: [SilenceTrimmer.KeepRange])
    /// No trimmed file was produced (either nothing worth trimming, or a safe failure fallback). The
    /// original file is untouched.
    case notTrimmed
}

/// Reads a finished `.m4a`, computes windowed RMS across it, feeds the pure `SilenceTrimmer` to get
/// keep-ranges, writes a trimmed copy of only those ranges to a temp file, and verifies it is a valid
/// non-empty audio file. It never touches the original: the caller adopts the verified temp through
/// the store's coordinated atomic-replace seam (`replaceAudio`), because the trim is non-reversible
/// and, on iCloud, the swap must be coordinated. Any failure returns `.notTrimmed` and writes nothing.
///
/// All AVFoundation work happens here so `SilenceTrimmer` (the analysis) and `TimingRemapper` (the
/// remap) stay pure. The type is `Sendable` and its one method is designed to run inside a detached
/// task off the main actor.
struct AudioTrimmer: AudioTrimming {
    /// The analysis window length. RMS is computed over this many seconds per window; it sets the
    /// resolution at which a silence boundary is found. 50ms is fine relative to a 2.0s min pause and
    /// a 0.6s breath gap, and keeps the window count modest for a long recording.
    static let windowSeconds: Double = 0.05

    let silenceFloor: Float
    let minPauseSeconds: Double
    let breathGapSeconds: Double
    /// The output-validity check run on the trimmed temp file before it is returned to the caller.
    /// Injectable so a test can force it to fail and exercise the non-reversible SAFETY branch (the
    /// trimmed file is discarded and `.notTrimmed` returned, leaving the original intact). Defaults to
    /// the real `isValidNonEmptyAudio`.
    private let validateOutput: (@Sendable (URL) -> Bool)?

    init(
        silenceFloor: Float = SilenceTrimmer.silenceFloor,
        minPauseSeconds: Double = SilenceTrimmer.minPauseSeconds,
        breathGapSeconds: Double = SilenceTrimmer.breathGapSeconds,
        validateOutput: (@Sendable (URL) -> Bool)? = nil
    ) {
        self.silenceFloor = silenceFloor
        self.minPauseSeconds = minPauseSeconds
        self.breathGapSeconds = breathGapSeconds
        self.validateOutput = validateOutput
    }

    func trim(fileAt url: URL) async -> AudioTrimResult {
        do {
            return try performTrim(fileAt: url)
        } catch {
            // Any failure (read, analysis, write, verify, replace) leaves the ORIGINAL untouched.
            // The recording is never lost for the sake of a trim.
            return .notTrimmed
        }
    }

    /// The trim body, factored so the outer `trim` can swallow every failure into `.notTrimmed`.
    private func performTrim(fileAt url: URL) throws -> AudioTrimResult {
        let source = try AVAudioFile(forReading: url)
        let format = source.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = source.length
        guard sampleRate > 0, totalFrames > 0 else { return .notTrimmed }

        let totalDuration = Double(totalFrames) / sampleRate
        let windowRMS = try computeWindowRMS(from: source, format: format, sampleRate: sampleRate)

        let keepRanges = SilenceTrimmer.keepRanges(
            windowRMS: windowRMS,
            windowSeconds: Self.windowSeconds,
            silenceFloor: silenceFloor,
            minPauseSeconds: minPauseSeconds,
            breathGapSeconds: breathGapSeconds
        )
        let removed = SilenceTrimmer.removedRanges(keepRanges: keepRanges, totalDuration: totalDuration)

        // Nothing to remove (no trimmable silence), or the analysis would drop everything: leave the
        // file exactly as captured. `keepRanges` empty only for an all-silent clip - we would rather
        // keep an all-silent recording than replace it with an empty file.
        guard !removed.isEmpty, !keepRanges.isEmpty else { return .notTrimmed }

        let tempURL = try writeTrimmed(keepRanges: keepRanges, source: url)

        // Verify the output is a real, non-empty audio file before handing it to the caller to adopt.
        // The ORIGINAL is never touched here: the caller swaps in this verified temp through the store's
        // coordinated atomic-replace seam (so an iCloud swap goes through NSFileCoordinator). On a
        // verify failure the temp is discarded and the original stays exactly as captured.
        let isValid = (validateOutput ?? { self.isValidNonEmptyAudio(at: $0) })(tempURL)
        guard isValid else {
            try? FileManager.default.removeItem(at: tempURL)
            return .notTrimmed
        }
        return .trimmed(trimmedFileURL: tempURL, removedRanges: removed)
    }

    /// Read the whole file in chunks and produce one RMS value per `windowSeconds` window. RMS is the
    /// max across channels within a window so a stereo silence is only silence when BOTH channels are.
    private func computeWindowRMS(
        from file: AVAudioFile,
        format: AVAudioFormat,
        sampleRate: Double
    ) throws -> [Float] {
        let windowFrames = max(1, Int(Self.windowSeconds * sampleRate))
        let channelCount = Int(format.channelCount)
        let totalFrames = file.length
        guard totalFrames > 0 else { return [] }

        // Read the whole recording into one buffer. On-device dictation recordings are bounded (minutes,
        // not hours), so this is a modest allocation and avoids the per-chunk read-loop edge cases; a
        // read cannot span a window boundary because there is only one read.
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)) else {
            throw TrimError.bufferAllocationFailed
        }
        file.framePosition = 0
        try file.read(into: buffer)
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return [] }

        var windowRMS: [Float] = []
        windowRMS.reserveCapacity(frames / windowFrames + 1)
        var sumSquares = 0.0
        var samplesInWindow = 0
        for frame in 0..<frames {
            var peak: Float = 0
            for channel in 0..<channelCount {
                let sample = channels[channel][frame]
                peak = max(peak, abs(sample))
            }
            sumSquares += Double(peak) * Double(peak)
            samplesInWindow += 1
            if samplesInWindow == windowFrames {
                windowRMS.append(Float((sumSquares / Double(samplesInWindow)).squareRoot()))
                sumSquares = 0
                samplesInWindow = 0
            }
        }
        // Flush a trailing partial window so the final tail of audio is represented.
        if samplesInWindow > 0 {
            windowRMS.append(Float((sumSquares / Double(samplesInWindow)).squareRoot()))
        }
        return windowRMS
    }

    /// Write a trimmed `.m4a` to a temp URL containing only `keepRanges`, by READING the kept frame
    /// ranges from the source `AVAudioFile` and WRITING them, in order, into a fresh AAC file. This
    /// is deterministic and self-contained (no `AVAsset` track loading or `AVAssetExportSession`,
    /// which are async / load-gated on modern iOS), so the whole trim is a straight-line off-main
    /// read/write. The output AAC settings mirror the capture writer so the result is the same family.
    private func writeTrimmed(
        keepRanges: [SilenceTrimmer.KeepRange],
        source url: URL
    ) throws -> URL {
        let source = try AVAudioFile(forReading: url)
        let format = source.processingFormat
        let totalFrames = source.length

        let fm = FileManager.default
        let tempURL = fm.temporaryDirectory
            .appendingPathComponent("thoughtstream-trim-\(UUID().uuidString).\(ThoughtStore.audioFileExtension)")
        try? fm.removeItem(at: tempURL)

        // Create the temp file PROTECTED (`completeUnlessOpen`) before `AVAudioFile` writes any audio
        // into it, mirroring `RecordingWriter`: raw audio is sensitive, so there must be no window where
        // the trimmed `.m4a` exists on disk unprotected. `AVAudioFile(forWriting:)` then opens this
        // existing (empty, already-protected) file rather than creating an unprotected one.
        fm.createFile(
            atPath: tempURL.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
        )

        // Remove the partial temp on EVERY early/error exit (a throw from open/copy/write, or the
        // empty-result guard), so a mid-write failure never orphans a partial copy of raw voice in the
        // shared temp dir. Only a clean success clears the flag and keeps the file for the caller.
        var succeeded = false
        defer { if !succeeded { try? fm.removeItem(at: tempURL) } }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let output = try AVAudioFile(forWriting: tempURL, settings: settings)

        var wroteAnyFrames = false
        for keep in keepRanges {
            let startFrame = AVAudioFramePosition((keep.start * format.sampleRate).rounded())
            let endFrame = min(totalFrames, AVAudioFramePosition((keep.end * format.sampleRate).rounded()))
            guard endFrame > startFrame else { continue }
            try copyFrames(from: source, to: output, startFrame: startFrame, endFrame: endFrame, format: format)
            wroteAnyFrames = true
        }
        guard wroteAnyFrames else { throw TrimError.emptyResult }
        succeeded = true
        return tempURL
    }

    /// Copy `[startFrame, endFrame)` from `source` to `output`, chunked so a long segment does not need
    /// one huge buffer. `source.framePosition` is seeked to the segment start, then frames are read and
    /// written until the segment is exhausted.
    private func copyFrames(
        from source: AVAudioFile,
        to output: AVAudioFile,
        startFrame: AVAudioFramePosition,
        endFrame: AVAudioFramePosition,
        format: AVAudioFormat
    ) throws {
        let chunkFrames = AVAudioFrameCount(max(1, Int(format.sampleRate))) // ~1s per read
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw TrimError.bufferAllocationFailed
        }
        source.framePosition = startFrame
        var remaining = endFrame - startFrame
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
    /// the original is never replaced unless the trimmed output has bytes AND opens with frames.
    func isValidNonEmptyAudio(at url: URL) -> Bool {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
        guard size > 0 else { return false }
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0
    }

    private enum TrimError: Error {
        case bufferAllocationFailed
        case emptyResult
    }
}
