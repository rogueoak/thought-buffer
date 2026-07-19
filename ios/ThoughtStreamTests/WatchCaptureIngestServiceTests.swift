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
}
