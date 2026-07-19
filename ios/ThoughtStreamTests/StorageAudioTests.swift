import XCTest
@testable import ThoughtStream

/// The storage layer's management of the sibling audio file (spec 0007): both `NoteStore` and the
/// coordinated `ICloudNoteStore` place `<id>.m4a` next to `<id>.md`, adopt a captured recording, and
/// delete the audio when the note is deleted.
final class StorageAudioTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageAudioTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - NoteStore

    func testLocalStoreSavesAndLocatesAudioSibling() throws {
        let store = NoteStore(directory: tempDir)
        let id = UUID()
        let audioURL = try XCTUnwrap(store.audioURL(for: id))
        XCTAssertEqual(audioURL.lastPathComponent, "\(id.uuidString).m4a")

        let saved = try store.saveAudio(from: makeTempRecording(), for: id)
        XCTAssertEqual(saved, audioURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }

    func testNoteWithAudioRoundTripsThroughTheStore() throws {
        // The frontmatter round-trip and the sibling file are proven separately elsewhere; this
        // proves the actual persistence path the app uses - save a note carrying audio + timings,
        // load it back, and get the recording metadata intact (spec 0007 round trip through storage).
        let store = NoteStore(directory: tempDir)
        let id = UUID()
        let timings = [
            ParagraphTiming(start: 0, duration: 2.0),
            ParagraphTiming(start: 2.0, duration: 3.5),
        ]
        let note = Note(
            id: id, title: "Recorded", paragraphs: ["One.", "Two."], createdAt: Date(),
            audioFileName: "\(id.uuidString).m4a", timings: timings
        )
        try store.save(note)

        let loaded = try XCTUnwrap(store.load(id: id))
        XCTAssertTrue(loaded.hasAudio)
        XCTAssertEqual(loaded.audioFileName, "\(id.uuidString).m4a")
        XCTAssertEqual(loaded.timings, timings)
        XCTAssertEqual(loaded.paragraphs, note.paragraphs)
    }

    func testAudioExistsReflectsSibling() throws {
        let store = NoteStore(directory: tempDir)
        let id = UUID()
        XCTAssertFalse(store.audioExists(for: id))
        try store.saveAudio(from: makeTempRecording(), for: id)
        XCTAssertTrue(store.audioExists(for: id))

        // The coordinated iCloud check sees the same on-disk file in this temp dir.
        let cloud = ICloudNoteStore.forTesting(directory: tempDir)
        XCTAssertTrue(cloud.audioExists(for: id))
        XCTAssertFalse(cloud.audioExists(for: UUID()))
    }

    func testLocalDeleteRemovesAudioSibling() throws {
        let store = NoteStore(directory: tempDir)
        let id = UUID()
        let note = Note(
            id: id, title: "n", paragraphs: ["Body."], createdAt: Date(),
            audioFileName: "\(id.uuidString).m4a",
            timings: [ParagraphTiming(start: 0, duration: 1)]
        )
        try store.save(note)
        try store.saveAudio(from: makeTempRecording(), for: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: id)!.path))

        // Deleting the note removes both the .md and the .m4a - no orphan recording.
        try store.delete(id: id)
        XCTAssertNil(store.load(id: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(for: id)!.path))
    }

    func testSaveAudioOverwritesExisting() throws {
        let store = NoteStore(directory: tempDir)
        let id = UUID()
        try store.saveAudio(from: makeTempRecording(content: "first"), for: id)
        try store.saveAudio(from: makeTempRecording(content: "second"), for: id)
        let data = try Data(contentsOf: store.audioURL(for: id)!)
        XCTAssertEqual(String(data: data, encoding: .utf8), "second")
    }

    // MARK: - replaceAudio (spec 0019 dead-air trim)

    func testReplaceAudioSwapsAnExistingRecording() throws {
        let store = NoteStore(directory: tempDir)
        let id = UUID()
        try store.saveAudio(from: makeTempRecording(content: "original"), for: id)
        let replaced = try XCTUnwrap(try store.replaceAudio(from: makeTempRecording(content: "trimmed"), for: id))
        XCTAssertEqual(replaced, store.audioURL(for: id))
        XCTAssertEqual(String(data: try Data(contentsOf: replaced), encoding: .utf8), "trimmed")
    }

    func testReplaceAudioWhenAbsentCreatesNoFileAndConsumesTemp() throws {
        // The load-bearing safety: replaceAudio must NEVER materialize a recording when the slot is
        // absent (a deleted/moved note), or it orphans a copy of raw voice. It returns nil and deletes
        // the temp instead.
        let store = NoteStore(directory: tempDir)
        let id = UUID()
        let temp = try makeTempRecording(content: "trimmed")
        let result = try store.replaceAudio(from: temp, for: id)
        XCTAssertNil(result, "nothing to replace -> nil")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(for: id)!.path),
                       "no orphan .m4a is created at the slot")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path), "the temp was consumed")
    }

    func testReplaceAudioFailureLeavesOriginalIntact() throws {
        // A replace whose SOURCE temp does not exist throws, and the original recording survives
        // byte-for-byte (replaceItemAt is atomic; nothing is destroyed on failure).
        let store = NoteStore(directory: tempDir)
        let id = UUID()
        try store.saveAudio(from: makeTempRecording(content: "original"), for: id)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).m4a")
        XCTAssertThrowsError(try store.replaceAudio(from: missing, for: id))
        XCTAssertEqual(String(data: try Data(contentsOf: store.audioURL(for: id)!), encoding: .utf8),
                       "original", "the original recording is intact after a failed replace")
    }

    func testICloudReplaceAudioSwapsExistingCoordinated() throws {
        // The coordinated NSFileCoordinator .forReplacing variant - the load-bearing iCloud safety - was
        // previously untested. Prove it swaps an existing recording in place.
        let store = ICloudNoteStore.forTesting(directory: tempDir)
        let id = UUID()
        try store.saveAudio(from: makeTempRecording(content: "original"), for: id)
        let replaced = try XCTUnwrap(try store.replaceAudio(from: makeTempRecording(content: "trimmed"), for: id))
        XCTAssertEqual(String(data: try Data(contentsOf: replaced), encoding: .utf8), "trimmed")
    }

    func testICloudReplaceAudioWhenAbsentCreatesNoFileAndConsumesTemp() throws {
        let store = ICloudNoteStore.forTesting(directory: tempDir)
        let id = UUID()
        let temp = try makeTempRecording(content: "trimmed")
        let result = try store.replaceAudio(from: temp, for: id)
        XCTAssertNil(result)
        XCTAssertFalse(store.audioExists(for: id), "no orphan .m4a created via the coordinated path")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path), "the temp was consumed")
    }

    func testICloudReplaceAudioFailureLeavesOriginalIntact() throws {
        let store = ICloudNoteStore.forTesting(directory: tempDir)
        let id = UUID()
        try store.saveAudio(from: makeTempRecording(content: "original"), for: id)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).m4a")
        XCTAssertThrowsError(try store.replaceAudio(from: missing, for: id))
        XCTAssertEqual(String(data: try Data(contentsOf: store.audioURL(for: id)!), encoding: .utf8),
                       "original")
    }

    // MARK: - ICloudNoteStore (coordinated)

    func testICloudStoreSavesAndDeletesAudioSiblingCoordinated() throws {
        let store = ICloudNoteStore.forTesting(directory: tempDir)
        let id = UUID()
        let audioURL = try XCTUnwrap(store.audioURL(for: id))
        XCTAssertEqual(audioURL.lastPathComponent, "\(id.uuidString).m4a")

        try store.saveAudio(from: makeTempRecording(), for: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

        // The coordinated delete removes both the note and its recording.
        let note = Note(
            id: id, title: "n", paragraphs: ["Body."], createdAt: Date(),
            audioFileName: "\(id.uuidString).m4a",
            timings: [ParagraphTiming(start: 0, duration: 1)]
        )
        try store.save(note)
        try store.delete(id: id)
        XCTAssertNil(store.load(id: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testDeleteAudioIsNoOpWhenMissing() throws {
        let store = NoteStore(directory: tempDir)
        XCTAssertNoThrow(try store.deleteAudio(for: UUID()))
        let cloud = ICloudNoteStore.forTesting(directory: tempDir)
        XCTAssertNoThrow(try cloud.deleteAudio(for: UUID()))
    }

    /// Write a stand-in recording to a temp file the store will move into place.
    private func makeTempRecording(content: String = "audio-bytes") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).m4a")
        try Data(content.utf8).write(to: url)
        return url
    }
}
