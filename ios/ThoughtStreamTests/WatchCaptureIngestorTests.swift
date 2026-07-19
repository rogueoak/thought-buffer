import XCTest
@testable import ThoughtStream

/// Tests for the pure watch-capture ingest decisions (spec 0023): building the filed thought from a
/// transcription outcome + metadata, the audio-only fallback (never drop a capture), and folder-hint
/// resolution. All pure, so provable without a live recognizer or a real watch.
final class WatchCaptureIngestorTests: XCTestCase {
    private let captureID = UUID()
    private let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func metadata(folder: [String] = []) -> WatchCaptureMetadata {
        WatchCaptureMetadata(captureID: captureID, capturedAt: capturedAt, folderHint: folder)
    }

    // MARK: Transcribed thought

    func testTranscribedThoughtCarriesParagraphsTimingsAndDerivedTitle() {
        let mapping = FileTranscriptionMapper.Mapping(
            paragraphs: ["Call the supplier. Then draft the email.", "A second thought."],
            timings: [ParagraphTiming(start: 0, duration: 4), ParagraphTiming(start: 4, duration: 3)]
        )
        let thought = WatchCaptureIngestor.buildThought(
            from: .transcribed(mapping),
            metadata: metadata(),
            resolvedFolderPath: [],
            audioFileName: "\(captureID.uuidString).m4a",
            audioDuration: 7
        )

        XCTAssertEqual(thought.id, captureID)
        XCTAssertEqual(thought.createdAt, capturedAt)
        XCTAssertEqual(thought.paragraphs.count, 2)
        // Title is the first sentence of the first paragraph (spec 0009).
        XCTAssertEqual(thought.title, "Call the supplier")
        XCTAssertFalse(thought.hasCustomTitle)
        XCTAssertTrue(thought.hasAudio)
        XCTAssertEqual(thought.timings.count, 2)
        XCTAssertEqual(thought.audioFileName, "\(captureID.uuidString).m4a")
    }

    // MARK: Audio-only fallback

    func testAudioOnlyFallbackFilesPlayableAudioWithTimestampTitle() {
        let thought = WatchCaptureIngestor.buildThought(
            from: .audioOnly,
            metadata: metadata(),
            resolvedFolderPath: [],
            audioFileName: "\(captureID.uuidString).m4a",
            audioDuration: 9.5
        )
        XCTAssertTrue(thought.paragraphs.isEmpty)
        XCTAssertTrue(thought.title.hasPrefix("Voice thought - "))
        // The recording is STILL attached (never drop a capture) with a whole-file timing, so it plays.
        XCTAssertTrue(thought.hasAudio)
        XCTAssertEqual(thought.timings, [ParagraphTiming(start: 0, duration: 9.5)])
        XCTAssertEqual(thought.recordingDuration, 9.5, accuracy: 0.001)
    }

    func testTranscribedButEmptyMappingFallsBackToAudioOnly() {
        // The recognizer ran but found no words: still filed audio-only, never dropped.
        let thought = WatchCaptureIngestor.buildThought(
            from: .transcribed(.empty),
            metadata: metadata(),
            resolvedFolderPath: [],
            audioFileName: "\(captureID.uuidString).m4a",
            audioDuration: 5
        )
        XCTAssertTrue(thought.paragraphs.isEmpty)
        XCTAssertTrue(thought.hasAudio)
        XCTAssertTrue(thought.title.hasPrefix("Voice thought - "))
    }

    func testAudioOnlyWithUnusableDurationIsTextOnly() {
        // A 0-duration (unreadable) recording cannot be a playable audio-only thought: no audio attached.
        let thought = WatchCaptureIngestor.buildThought(
            from: .audioOnly,
            metadata: metadata(),
            resolvedFolderPath: [],
            audioFileName: "\(captureID.uuidString).m4a",
            audioDuration: 0
        )
        XCTAssertFalse(thought.hasAudio)
        XCTAssertNil(thought.audioFileName)
        XCTAssertTrue(thought.timings.isEmpty)
    }

    // MARK: Folder-hint resolution

    func testFolderHintResolvesWhenFolderExists() {
        let resolved = WatchCaptureIngestor.resolveFolderPath(
            hint: ["Work"], existingFolderPaths: [["Work"], ["Personal"]])
        XCTAssertEqual(resolved, ["Work"])
    }

    func testFolderHintFallsBackToTopLevelWhenFolderGone() {
        let resolved = WatchCaptureIngestor.resolveFolderPath(
            hint: ["Deleted"], existingFolderPaths: [["Work"]])
        XCTAssertEqual(resolved, [])
    }

    func testEmptyFolderHintStaysTopLevel() {
        let resolved = WatchCaptureIngestor.resolveFolderPath(hint: [], existingFolderPaths: [["Work"]])
        XCTAssertEqual(resolved, [])
    }

    func testNestedFolderHintResolvesOnlyWhenFullPathExists() {
        let existing = [["Work"], ["Work", "Ideas"]]
        XCTAssertEqual(WatchCaptureIngestor.resolveFolderPath(hint: ["Work", "Ideas"], existingFolderPaths: existing), ["Work", "Ideas"])
        // A partial match is not enough: the exact path must exist.
        XCTAssertEqual(WatchCaptureIngestor.resolveFolderPath(hint: ["Work", "Missing"], existingFolderPaths: existing), [])
    }
}
