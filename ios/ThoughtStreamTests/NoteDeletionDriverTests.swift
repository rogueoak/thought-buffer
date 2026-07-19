import XCTest
@testable import ThoughtStream

/// The undoable-delete seam driven through `StreamFeed`/`NoteStoreDriver` over a REAL `NoteStore`
/// (temp dir), spec 0020. Proves that a delete produces a restorable token, that restore re-inserts the
/// note (and its audio) at the right location, and that purge removes it - without any live UndoManager
/// or shake gesture (a system gesture, verified manually), by exercising the underlying seam the shake
/// and the in-app affordance both call.
@MainActor
final class NoteDeletionDriverTests: XCTestCase {
    private var tempDir: URL!
    private var store: NoteStore!
    private var feed: StreamFeed!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteDeletionDriverTests-\(UUID().uuidString)", isDirectory: true)
        store = NoteStore(directory: tempDir)
        feed = StreamFeed(store: store)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    /// Deleting through the feed removes the note from the list AND returns a token whose restore
    /// re-inserts the note (with its audio) at its original folder.
    func testDeleteReturnsTokenAndRestoreReinsertsNoteAndAudio() async throws {
        let id = UUID()
        let note = Note(id: id, title: "Recoverable", paragraphs: ["Body."], createdAt: Date(),
                        folderPath: ["Work"])
        try store.save(note)
        try store.saveAudio(from: makeTempRecording(), for: id)
        await feed.reload()
        XCTAssertEqual(feed.notes.count, 1)

        let genBeforeDelete = feed.reloadGeneration
        let deleted = await feed.delete(id: id)
        let token = try XCTUnwrap(deleted)
        XCTAssertEqual(token.formerFolderPath, ["Work"])
        XCTAssertEqual(feed.notes.count, 0, "delete removes the note from the list")
        XCTAssertFalse(feed.deleteFailed)
        XCTAssertGreaterThan(feed.reloadGeneration, genBeforeDelete,
                             "delete republishes the list, bumping the change token")

        let genBeforeRestore = feed.reloadGeneration
        await feed.restore(token)
        XCTAssertEqual(feed.notes.count, 1, "restore re-inserts the note")
        XCTAssertEqual(feed.notes.first?.folderPath, ["Work"])
        XCTAssertTrue(store.audioExists(for: id), "restore brings the audio back too")
        XCTAssertGreaterThan(feed.reloadGeneration, genBeforeRestore,
                             "restore republishes the list, bumping the change token")
    }

    /// Purging a deleted note's token removes it permanently: after purge, restore recovers nothing and
    /// the list stays empty.
    func testPurgeRemovesDeletedNotePermanently() async throws {
        let note = Note(title: "Doomed", paragraphs: ["Body."], createdAt: Date())
        try store.save(note)
        await feed.reload()

        let deleted = await feed.delete(id: note.id)
        let token = try XCTUnwrap(deleted)
        await feed.purge(token)
        await feed.restore(token) // nothing left to restore
        XCTAssertEqual(feed.notes.count, 0)
        XCTAssertNil(store.load(id: note.id))
    }

    /// The launch-time trash sweep empties any leftover trash so it does not accumulate across launches.
    func testPurgeAllTrashClearsLeftoverTrash() async throws {
        let note = Note(title: "Trashed", paragraphs: ["Body."], createdAt: Date())
        try store.save(note)
        await feed.reload()
        let deleted = await feed.delete(id: note.id)
        let token = try XCTUnwrap(deleted)

        await feed.purgeAllTrash()
        await feed.restore(token) // the sweep already purged it
        XCTAssertNil(store.load(id: note.id))
    }

    private func makeTempRecording(content: String = "audio-bytes") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).m4a")
        try Data(content.utf8).write(to: url)
        return url
    }
}
