import Foundation

/// Turns a transferred watch recording into a filed thought on the phone (spec 0023). This is the
/// NEW phone-side capability: the watch records audio and syncs the `.m4a` + metadata; the phone
/// transcribes the file, builds a `Thought` (title + paragraphs + timings), attaches the audio, and
/// saves it through the existing store - into the folder hint when it still exists, else the top level.
///
/// The pure decisions (build the thought from a transcription mapping, resolve the folder hint, and the
/// audio-only fallback when transcription yields nothing) are factored into static functions so they are
/// unit-testable without a live mic, a real watch, or a running transcriber. The IO (transcribe the
/// file, move the audio into the store, save) is the thin, injected/device-verified shell around them.
///
/// FAILURE POLICY: the capture is NEVER dropped. If transcription fails or yields no text, the thought
/// is filed AUDIO-ONLY (title from the timestamp, no paragraphs, the recording attached) so the words
/// can be regenerated later - losing the audio would lose the whole thought.
enum WatchCaptureIngestor {
    /// The outcome of transcribing the transferred file, handed to the pure builder. `.transcribed`
    /// carries the mapped paragraphs + timings; `.audioOnly` is the fallback (transcription failed or
    /// found no speech) - the audio is still filed, just with no text.
    enum Transcription: Equatable {
        case transcribed(FileTranscriptionMapper.Mapping)
        case audioOnly
    }

    /// Build the thought to save from a transcription outcome and the capture metadata (PURE). The
    /// capture id becomes the thought id (so a re-delivered transfer overwrites rather than duplicates),
    /// the captured-at time becomes `createdAt` (so it sorts by when it was spoken, not received), and
    /// the folder is the resolved hint.
    ///
    /// The audio is ALWAYS attached (the recording is the capture; never dropped):
    /// - A `.transcribed` mapping WITH paragraphs yields a normal thought: title derived from the first
    ///   sentence (spec 0009), paragraphs and the mapping's per-paragraph timings.
    /// - A `.transcribed` mapping with NO paragraphs, and `.audioOnly`, both yield an AUDIO-ONLY thought:
    ///   a timestamp title and an empty body, but the recording is still attached with a single
    ///   WHOLE-FILE timing (`[0, audioDuration]`) so `Thought.hasAudio` is true and the recording plays
    ///   back. `audioDuration` is the recording's length (the caller reads it off the file); a
    ///   non-positive duration means an unusable recording, so no timing is attached and the thought is
    ///   truly text-only.
    static func buildThought(
        from transcription: Transcription,
        metadata: WatchCaptureMetadata,
        resolvedFolderPath: [String],
        audioFileName: String,
        audioDuration: Double,
        now: Date = Date()
    ) -> Thought {
        var paragraphs: [String] = []
        var timings: [ParagraphTiming] = []
        if case .transcribed(let mapping) = transcription {
            paragraphs = mapping.paragraphs
            timings = mapping.timings
        }

        let hasText = !paragraphs.isEmpty
        let title = hasText
            ? Thought.deriveTitle(paragraphs: paragraphs, createdAt: metadata.capturedAt)
            : audioOnlyTitle(capturedAt: metadata.capturedAt, now: now)

        // Audio-only (no transcript): attach the recording with ONE whole-file timing so it is playable
        // and `hasAudio` is true. A non-positive duration is an unusable file, so leave it text-only.
        if !hasText {
            if audioDuration > 0 {
                timings = [ParagraphTiming(start: 0, duration: audioDuration)]
            } else {
                timings = []
            }
        }

        // The audio filename is attached whenever there is at least one timing to pair it with, matching
        // `Thought.hasAudio`'s dual-guard (a filename with no timings would parse back as text-only).
        let attachedFileName: String? = timings.isEmpty ? nil : audioFileName

        return Thought(
            id: metadata.captureID,
            title: title,
            paragraphs: paragraphs,
            createdAt: metadata.capturedAt,
            hasCustomTitle: false,
            audioFileName: attachedFileName,
            timings: timings,
            folderPath: resolvedFolderPath
        )
    }

    /// A timestamp title for an audio-only thought (no transcript to derive from), e.g.
    /// "Voice thought - Jul 19, 2:04 PM". Pure so the fallback naming is unit-testable.
    static func audioOnlyTitle(capturedAt: Date, now: Date = Date()) -> String {
        "Voice thought - " + audioOnlyTitleFormatter.string(from: capturedAt)
    }

    /// Resolve the folder hint against the folders that currently exist on the phone (PURE). The watch's
    /// hint is advisory: the phone may have deleted or renamed the folder since. File into the hint only
    /// when the full path still exists; otherwise fall back to the TOP LEVEL (never a failure, never a
    /// dropped capture). `existingFolderPaths` is the set of real folder paths the caller collected from
    /// the store (each an ordered `[String]`).
    static func resolveFolderPath(
        hint: [String],
        existingFolderPaths: [[String]]
    ) -> [String] {
        guard !hint.isEmpty else { return [] }
        return existingFolderPaths.contains(hint) ? hint : []
    }

    private static let audioOnlyTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
