import Foundation
import AVFoundation

/// The tee'd audio-file sink for a dictation session (spec 0007).
///
/// The capture service forks each input-tap buffer to two places: the speech recognizer (as
/// before) and this writer, which appends the same buffer to a compressed `.m4a` on disk. One
/// writer lives for the whole session, so the recording is continuous across the recognizer's
/// task restarts - restarts swap the recognition request, never this file.
///
/// Threading: `append(_:)` runs on the audio thread, and `elapsedSeconds` is read from the main
/// actor at each recognizer restart to anchor segment timings, so both touch shared state under a
/// lock. `AVAudioFile.write` is not itself thread-safe, so the lock is what makes concurrent
/// `append` calls (and the elapsed-seconds read) safe. The class is `@unchecked Sendable` because
/// all mutable state is guarded by that lock.
///
/// Privacy: raw audio is more sensitive than text. The file is created with
/// `FileProtection.completeUnlessOpen` and nothing about the audio is ever logged.
final class RecordingWriter: @unchecked Sendable {
    /// The temporary file the recording is written to. The caller adopts it into storage after
    /// `stop()` via `NoteStoring.saveAudio(from:for:)`.
    let url: URL

    private let lock = NSLock()
    private var file: AVAudioFile?
    /// Total frames appended so far, and the sample rate, so elapsed time is `frames / sampleRate`.
    /// This is the source of truth for the timing offset: audio seconds actually written, not wall
    /// clock, so a pause (no frames appended) does not advance the recording clock.
    private var framesWritten: AVAudioFramePosition = 0
    private var sampleRate: Double = 0
    private var didWriteAnyFrames = false

    /// Create a writer targeting a fresh temporary `.m4a`. The file is opened lazily on the first
    /// `append`, once the input format is known, so the AAC settings match the tap's sample rate.
    init() {
        let name = "thoughtstream-recording-\(UUID().uuidString).\(NoteStore.audioFileExtension)"
        self.url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: false)
    }

    /// Append a buffer to the recording, opening the file on the first call. Runs on the audio
    /// thread. Failures are swallowed (never logged) so a transient write error degrades to a
    /// shorter recording rather than crashing the capture session.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        do {
            let audioFile = try openIfNeeded(matching: buffer.format)
            try audioFile.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
            if buffer.frameLength > 0 { didWriteAnyFrames = true }
        } catch {
            // Intentionally silent: no audio content is logged, and a write hiccup should not tear
            // down dictation. The recording is best-effort.
        }
    }

    /// Seconds of audio written so far. Read on the main actor at each recognizer restart to convert
    /// a segment's request-relative timestamp into an absolute position in the recording.
    var elapsedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        guard sampleRate > 0 else { return 0 }
        return Double(framesWritten) / sampleRate
    }

    /// Whether any audio was actually written. False means the recording is empty (e.g. the mic
    /// produced nothing), so the caller should treat the session as having no recording.
    var hasContent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didWriteAnyFrames
    }

    /// Finish the recording, flushing and closing the file. Safe to call more than once. After this
    /// the file at `url` is complete and ready to be adopted into storage.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        // Releasing the AVAudioFile flushes and closes it; there is no explicit close API.
        file = nil
    }

    /// Delete the temporary file, if it exists. Used when the recording is discarded (empty, or the
    /// session produced no note to attach it to).
    func discard() {
        finish()
        try? FileManager.default.removeItem(at: url)
    }

    /// Open the output file on first use, using AAC settings derived from the tap format so the
    /// recording matches the mic's sample rate and channel count. Caller holds `lock`.
    private func openIfNeeded(matching format: AVAudioFormat) throws -> AVAudioFile {
        if let file { return file }
        // Create the file PROTECTED before `AVAudioFile` writes any audio into it, so there is never a
        // window where the `.m4a` exists on disk unprotected. `AVAudioFile(forWriting:)` opens the
        // existing (empty, already-protected) file rather than creating an unprotected one; the AAC
        // container header is then written into a file that was protected from byte zero.
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
            )
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let audioFile = try AVAudioFile(forWriting: url, settings: settings)
        // Re-assert protection after open in case the framework rewrote attributes; the file was
        // already protected above, so this only reinforces the guarantee (never opens a window).
        try? fm.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: url.path
        )
        file = audioFile
        sampleRate = format.sampleRate
        return audioFile
    }
}
