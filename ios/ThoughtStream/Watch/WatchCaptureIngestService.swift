import Foundation
@preconcurrency import AVFoundation

/// Ingests a transferred watch recording end to end on the phone (spec 0023): transcribe the file, build
/// a thought via the pure `WatchCaptureIngestor`, attach the audio, and save it through the existing
/// `ThoughtStoring`. This is the IO shell around the pure decisions; the mapping and fallback logic they
/// hold are unit-tested separately, and this service is unit-tested with a stub transcriber + store to
/// prove the two paths (transcribed vs. audio-only fallback) without a live recognizer or real watch.
///
/// It never drops a capture: a transcription throw or an empty result files the thought AUDIO-ONLY (the
/// recording is kept, the text can be regenerated later). The thought is saved FILE-FIRST then the audio
/// adopted, mirroring `DictationViewModel.saveCurrentThought`, so the `.m4a` lands beside the `.md` in the
/// resolved folder.
final class WatchCaptureIngestService: Sendable {
    private let store: ThoughtStoring
    private let transcriber: FileTranscribing

    init(store: ThoughtStoring, transcriber: FileTranscribing = SpeechAnalyzerFileTranscriber()) {
        self.store = store
        self.transcriber = transcriber
    }

    /// Ingest a recording the watch transferred: `fileURL` is the received `.m4a` (a temp location owned
    /// by the caller/WCSession), `metadata` its capture id / timestamp / folder hint. Returns the saved
    /// thought, or nil when there was nothing usable to save (an unreadable/empty file with no audio) -
    /// but a valid recording is ALWAYS saved (audio-only if transcription yields nothing).
    @discardableResult
    func ingest(fileURL: URL, metadata: WatchCaptureMetadata) async -> Thought? {
        // Transcribe the file. ANY failure (recognizer/model/unreadable) or an empty result becomes the
        // audio-only fallback: the capture is never dropped for want of a transcript.
        let transcription: WatchCaptureIngestor.Transcription
        if let segments = try? await transcriber.transcribe(fileAt: fileURL), !segments.isEmpty {
            let mapping = FileTranscriptionMapper.map(segments: segments)
            transcription = mapping.paragraphs.isEmpty ? .audioOnly : .transcribed(mapping)
        } else {
            transcription = .audioOnly
        }

        let audioDuration = Self.duration(ofFileAt: fileURL)
        let audioFileName = "\(metadata.captureID.uuidString).\(ThoughtStore.audioFileExtension)"
        let resolvedFolder = WatchCaptureIngestor.resolveFolderPath(
            hint: metadata.folderHint,
            existingFolderPaths: allFolderPaths()
        )

        let thought = WatchCaptureIngestor.buildThought(
            from: transcription,
            metadata: metadata,
            resolvedFolderPath: resolvedFolder,
            audioFileName: audioFileName,
            audioDuration: audioDuration
        )

        // Save FILE-FIRST (spec 0010): the store places the recording beside the located `.md`, so the
        // thought file must exist in its folder before the audio is adopted, or a foldered capture's
        // `.m4a` would land at the root. Then adopt the audio and re-save with the audio metadata.
        do {
            // Write the text shape first WITHOUT audio metadata so `.md` exists to locate.
            let textOnly = thought.withoutAudio()
            try store.save(textOnly)
            // Adopt the recording into the thought's slot beside the just-written `.md`.
            if thought.audioFileName != nil {
                try store.saveAudio(from: fileURL, for: thought.id)
                try store.save(thought)
            }
            return thought
        } catch {
            // A save failure leaves whatever was written; the capture file stays with the caller. Report
            // nil so the caller can log, but never crash the receive path.
            return nil
        }
    }

    /// Every existing folder path in the store (each an ordered `[String]`), for resolving the watch's
    /// folder hint. Derived from the loaded thoughts' `folderPath`s plus the empty folders the store
    /// reports, so a hint into an empty-but-present folder still resolves.
    private func allFolderPaths() -> [[String]] {
        var paths = Set<[String]>()
        for thought in store.loadAll() where !thought.folderPath.isEmpty {
            // Every ancestor prefix is a real folder too.
            for depth in 1...thought.folderPath.count {
                paths.insert(Array(thought.folderPath.prefix(depth)))
            }
        }
        // Include empty folders the store knows about (walk one level; the hint is typically shallow).
        collectFolders(at: [], into: &paths)
        return Array(paths)
    }

    /// Recursively collect folder paths the store reports, so an empty folder (never in any thought's
    /// path) is still offered as a hint target. Bounded to a shallow walk; watch captures file at or near
    /// the browsing folder, which is shallow.
    private func collectFolders(at path: [String], into paths: inout Set<[String]>) {
        for name in store.folders(at: path) {
            let child = path + [name]
            paths.insert(child)
            collectFolders(at: child, into: &paths)
        }
    }

    /// The duration in seconds of the audio file at `url`, or 0 when it cannot be read. Used to give an
    /// audio-only thought a whole-file timing so it stays playable.
    static func duration(ofFileAt url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else {
            return 0
        }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

private extension Thought {
    /// A copy with no recording attached, for the file-first save (the `.md` must exist before the audio
    /// is adopted). Preserves everything else.
    func withoutAudio() -> Thought {
        Thought(
            id: id,
            title: title,
            paragraphs: paragraphs,
            createdAt: createdAt,
            hasCustomTitle: hasCustomTitle,
            audioFileName: nil,
            timings: [],
            folderPath: folderPath
        )
    }
}
