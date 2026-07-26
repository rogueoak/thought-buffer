import XCTest
@testable import ThoughtBuffer

/// The undoable-delete seam driven through `StreamFeed`/`ThoughtStoreDriver` over a REAL `ThoughtStore`
/// (temp dir), spec 0020. Proves that a delete produces a restorable token, that restore re-inserts the
/// thought (and its audio) at the right location, and that purge removes it - without any live UndoManager
/// or shake gesture (a system gesture, verified manually), by exercising the underlying seam the shake
/// and the in-app affordance both call.
@MainActor
final class ThoughtDeletionDriverTests: XCTestCase {
    private var tempDir: URL!
    private var store: ThoughtStore!
    private var feed: StreamFeed!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThoughtDeletionDriverTests-\(UUID().uuidString)", isDirectory: true)
        store = ThoughtStore(directory: tempDir)
        feed = StreamFeed(store: store)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    /// Deleting through the feed removes the thought from the list AND returns a token whose restore
    /// re-inserts the thought (with its audio) at its original folder.
    func testDeleteReturnsTokenAndRestoreReinsertsThoughtAndAudio() async throws {
        let id = UUID()
        let thought = Thought(id: id, title: "Recoverable", paragraphs: ["Body."], createdAt: Date(),
                        folderPath: ["Work"])
        try store.save(thought)
        try store.saveAudio(from: makeTempRecording(), for: id)
        await feed.reload()
        XCTAssertEqual(feed.thoughts.count, 1)

        let genBeforeDelete = feed.reloadGeneration
        let deleted = await feed.delete(id: id)
        let token = try XCTUnwrap(deleted)
        XCTAssertEqual(token.formerFolderPath, ["Work"])
        XCTAssertEqual(feed.thoughts.count, 0, "delete removes the thought from the list")
        XCTAssertFalse(feed.deleteFailed)
        XCTAssertGreaterThan(feed.reloadGeneration, genBeforeDelete,
                             "delete republishes the list, bumping the change token")

        let genBeforeRestore = feed.reloadGeneration
        await feed.restore(token)
        XCTAssertEqual(feed.thoughts.count, 1, "restore re-inserts the thought")
        XCTAssertEqual(feed.thoughts.first?.folderPath, ["Work"])
        XCTAssertTrue(store.audioExists(for: id), "restore brings the audio back too")
        XCTAssertGreaterThan(feed.reloadGeneration, genBeforeRestore,
                             "restore republishes the list, bumping the change token")
    }

    /// Purging a deleted thought's token removes it permanently: after purge, restore recovers nothing and
    /// the list stays empty.
    func testPurgeRemovesDeletedThoughtPermanently() async throws {
        let thought = Thought(title: "Doomed", paragraphs: ["Body."], createdAt: Date())
        try store.save(thought)
        await feed.reload()

        let deleted = await feed.delete(id: thought.id)
        let token = try XCTUnwrap(deleted)
        await feed.purge(token)
        await feed.restore(token) // nothing left to restore
        XCTAssertEqual(feed.thoughts.count, 0)
        XCTAssertNil(store.load(id: thought.id))
    }

    /// The launch-time trash sweep empties any leftover trash so it does not accumulate across launches.
    func testPurgeAllTrashClearsLeftoverTrash() async throws {
        let thought = Thought(title: "Trashed", paragraphs: ["Body."], createdAt: Date())
        try store.save(thought)
        await feed.reload()
        let deleted = await feed.delete(id: thought.id)
        let token = try XCTUnwrap(deleted)

        await feed.purgeAllTrash()
        await feed.restore(token) // the sweep already purged it
        XCTAssertNil(store.load(id: thought.id))
    }

    private func makeTempRecording(content: String = "audio-bytes") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).m4a")
        try Data(content.utf8).write(to: url)
        return url
    }
}
