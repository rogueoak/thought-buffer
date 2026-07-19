import XCTest
import AVFoundation
@testable import ThoughtStream

/// End-to-end tests for the phone-side ingest of a transferred watch recording (spec 0023), with a STUB
/// transcriber and a REAL `ThoughtStore` in a temp directory. Proves the two paths - transcribed vs.
/// audio-only fallback - without a live recognizer or a real watch: a stub returns fixed segments or
/// throws, and the assertions read the saved thought back off disk.
final class WatchCaptureIngestServiceTests: XCTestCase {
    private var directory: URL!
    private var store: ThoughtStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-ingest-\(UUID().uuidString)", isDirectory: true)
        store = ThoughtStore(directory: directory)
        try store.ensureDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A stub `FileTranscribing`: returns fixed segments, or throws to exercise the audio-only fallback.
    private struct StubTranscriber: FileTranscribing {
        let segments: [TranscribedSegment]
        let error: Error?
        func transcribe(fileAt url: URL) async throws -> [TranscribedSegment] {
            if let error { throw error }
            return segments
        }
    }

    /// A `FileTranscribing` that COUNTS its calls, so a test can prove a re-delivered capture is NOT
    /// re-transcribed (the idempotency guard skips the whole ingest).
    private final class CountingTranscriber: FileTranscribing, @unchecked Sendable {
        let segments: [TranscribedSegment]
        private let lock = NSLock()
        private var _callCount = 0
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }

        init(segments: [TranscribedSegment]) { self.segments = segments }

        func transcribe(fileAt url: URL) async throws -> [TranscribedSegment] {
            recordCall()
            return segments
        }

        /// Synchronous so the `NSLock` is never taken directly from the async `transcribe`
        /// (the "lock unavailable from asynchronous contexts" Swift 6 warning).
        private func recordCall() { lock.lock(); _callCount += 1; lock.unlock() }
    }

    /// Write a short real `.m4a` (via the existing `RecordingWriter`) so the ingest service reads a real
    /// duration off it. Returns the file URL.
    private func makeRecording(seconds: Double = 1.0) throws -> URL {
        let writer = RecordingWriter()
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<Int(frames) { channel[i] = Float(sin(Double(i) * 0.05)) * 0.3 }
        }
        writer.append(buffer)
        writer.finish()
        return writer.url
    }

    func testTranscribedCaptureIsFiledWithTextAndAudio() async throws {
        let fileURL = try makeRecording(seconds: 1.0)
        let service = WatchCaptureIngestService(
            store: store,
            transcriber: StubTranscriber(
                segments: [TranscribedSegment(text: "Call the supplier today", startSeconds: 0, durationSeconds: 1)],
                error: nil))

        let metadata = WatchCaptureMetadata(captureID: UUID(), capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let thought = await service.ingest(fileURL: fileURL, metadata: metadata)

        XCTAssertNotNil(thought)
        // Reloaded from disk: the thought is filed with text, and its audio sits beside it.
        let loaded = store.loadAll().first { $0.id == metadata.captureID }
        XCTAssertEqual(loaded?.paragraphs, ["Call the supplier today"])
        XCTAssertEqual(loaded?.title, "Call the supplier today")
        XCTAssertTrue(loaded?.hasAudio ?? false)
        XCTAssertTrue(store.audioExists(for: metadata.captureID))
    }

    func testTranscriptionFailureFilesAudioOnly() async throws {
        let fileURL = try makeRecording(seconds: 1.0)
        let service = WatchCaptureIngestService(
            store: store,
            transcriber: StubTranscriber(segments: [], error: FileTranscriptionError.recognizerUnavailable))

        let metadata = WatchCaptureMetadata(captureID: UUID(), capturedAt: Date())
        let thought = await service.ingest(fileURL: fileURL, metadata: metadata)

        XCTAssertNotNil(thought)
        let loaded = store.loadAll().first { $0.id == metadata.captureID }
        // The capture is NOT dropped: filed audio-only (no text, but a playable recording).
        XCTAssertTrue(loaded?.paragraphs.isEmpty ?? false)
        XCTAssertTrue(loaded?.title.hasPrefix("Voice thought - ") ?? false)
        XCTAssertTrue(loaded?.hasAudio ?? false)
        XCTAssertTrue(store.audioExists(for: metadata.captureID))
    }

    func testEmptyTranscriptionFilesAudioOnly() async throws {
        let fileURL = try makeRecording(seconds: 1.0)
        let service = WatchCaptureIngestService(
            store: store,
            transcriber: StubTranscriber(segments: [], error: nil)) // ran, found nothing

        let metadata = WatchCaptureMetadata(captureID: UUID(), capturedAt: Date())
        _ = await service.ingest(fileURL: fileURL, metadata: metadata)

        let loaded = store.loadAll().first { $0.id == metadata.captureID }
        XCTAssertTrue(loaded?.hasAudio ?? false)
        XCTAssertTrue(loaded?.paragraphs.isEmpty ?? false)
    }

    func testFolderHintFilesIntoExistingFolder() async throws {
        _ = try store.createFolder(named: "Work", at: [])
        let fileURL = try makeRecording(seconds: 1.0)
        let service = WatchCaptureIngestService(
            store: store,
            transcriber: StubTranscriber(
                segments: [TranscribedSegment(text: "In a folder", startSeconds: 0, durationSeconds: 1)],
                error: nil))

        let metadata = WatchCaptureMetadata(captureID: UUID(), capturedAt: Date(), folderHint: ["Work"])
        _ = await service.ingest(fileURL: fileURL, metadata: metadata)

        let loaded = store.loadAll().first { $0.id == metadata.captureID }
        XCTAssertEqual(loaded?.folderPath, ["Work"])
    }

    func testUnknownFolderHintFallsBackToTopLevel() async throws {
        let fileURL = try makeRecording(seconds: 1.0)
        let service = WatchCaptureIngestService(
            store: store,
            transcriber: StubTranscriber(
                segments: [TranscribedSegment(text: "No such folder", startSeconds: 0, durationSeconds: 1)],
                error: nil))

        let metadata = WatchCaptureMetadata(captureID: UUID(), capturedAt: Date(), folderHint: ["Ghost"])
        _ = await service.ingest(fileURL: fileURL, metadata: metadata)

        let loaded = store.loadAll().first { $0.id == metadata.captureID }
        XCTAssertEqual(loaded?.folderPath, [])
    }

    func testHostileFolderHintLandsAtTopLevel() async throws {
        // A traversal / absolute / garbage hint must resolve to the TOP LEVEL, proving the allowlist
        // (resolveFolderPath only accepts an EXISTING path) plus the store's own name sanitization defend
        // the tree - the file never escapes to a crafted directory.
        for hint in [[".."], ["/etc"], ["..", ".."], ["\u{0}"], ["a/b"]] {
            let fileURL = try makeRecording(seconds: 1.0)
            let service = WatchCaptureIngestService(
                store: store,
                transcriber: StubTranscriber(
                    segments: [TranscribedSegment(text: "Hostile hint", startSeconds: 0, durationSeconds: 1)],
                    error: nil))
            let metadata = WatchCaptureMetadata(captureID: UUID(), capturedAt: Date(), folderHint: hint)
            _ = await service.ingest(fileURL: fileURL, metadata: metadata)

            let loaded = store.loadAll().first { $0.id == metadata.captureID }
            XCTAssertEqual(loaded?.folderPath, [], "hint \(hint) should land at top level")
        }
    }

    // MARK: Idempotency (re-delivery)

    func testReDeliveryYieldsOneThoughtAndDoesNotReTranscribe() async throws {
        let captureID = UUID()
        let counting = CountingTranscriber(
            segments: [TranscribedSegment(text: "First delivery", startSeconds: 0, durationSeconds: 1)])
        let service = WatchCaptureIngestService(store: store, transcriber: counting)

        let metadata = WatchCaptureMetadata(captureID: captureID, capturedAt: Date())
        _ = await service.ingest(fileURL: try makeRecording(), metadata: metadata)
        // Deliver the SAME capture again (WatchConnectivity can re-deliver a transfer).
        _ = await service.ingest(fileURL: try makeRecording(), metadata: metadata)

        // Exactly ONE thought, and the second delivery did NOT re-run transcription.
        XCTAssertEqual(store.loadAll().filter { $0.id == captureID }.count, 1)
        XCTAssertEqual(counting.callCount, 1)
    }

    func testPhoneEditBetweenDeliveriesIsPreserved() async throws {
        let captureID = UUID()
        let service = WatchCaptureIngestService(
            store: store,
            transcriber: StubTranscriber(
                segments: [TranscribedSegment(text: "Original text", startSeconds: 0, durationSeconds: 1)],
                error: nil))
        let metadata = WatchCaptureMetadata(captureID: captureID, capturedAt: Date())

        // First delivery files the thought.
        _ = await service.ingest(fileURL: try makeRecording(), metadata: metadata)

        // The user edits it on the phone between deliveries.
        let filed = try XCTUnwrap(store.loadAll().first { $0.id == captureID })
        let edited = filed.editedCopy(
            paragraphs: ["Edited on the phone"], hasCustomTitle: true, customTitle: "My title")
        try store.save(edited)

        // The SAME capture is re-delivered: it must be a NO-OP, preserving the edit (not clobbering it).
        _ = await service.ingest(fileURL: try makeRecording(), metadata: metadata)

        let after = try XCTUnwrap(store.loadAll().first { $0.id == captureID })
        XCTAssertEqual(after.paragraphs, ["Edited on the phone"])
        XCTAssertEqual(after.title, "My title")
    }
}
