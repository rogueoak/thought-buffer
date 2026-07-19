import XCTest
@testable import ThoughtStream

/// Folder rename through the async seam the UI calls (spec 0021 bug fix). The store-level rename is
/// already covered (`ThoughtStoreTests`/`ICloudThoughtStoreTests`); these prove that driving it through
/// `StreamFeed.renameFolder(at:to:)` - the exact call the folder screen makes - renames the folder on
/// disk, moves its thoughts with it, RETURNS the applied name, and republishes so the list reflects the
/// new location. A regression here would be the rename appearing to do nothing in the UI.
@MainActor
final class FolderRenameDriverTests: XCTestCase {
    private var tempDir: URL!
    private var store: ThoughtStore!
    private var feed: StreamFeed!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderRenameDriverTests-\(UUID().uuidString)", isDirectory: true)
        store = ThoughtStore(directory: tempDir)
        feed = StreamFeed(store: store)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    private func thought(_ title: String, folder: [String]) -> Thought {
        Thought(title: title, paragraphs: ["body"], createdAt: Date(), folderPath: folder)
    }

    func testRenameFolderThroughFeedRenamesOnDiskAndReturnsName() async throws {
        try store.save(thought("in old", folder: ["Old"]))
        await feed.start()

        let applied = await feed.renameFolder(at: ["Old"], to: "New")

        // The applied (sanitized) name flows back to the caller ...
        XCTAssertEqual(applied, "New")
        // ... the folder is renamed on disk (old gone, new present) ...
        XCTAssertFalse(store.folders(at: []).contains("Old"))
        XCTAssertTrue(store.folders(at: []).contains("New"))
        // ... the thought moved with it (its folderPath is now the new name) ...
        let moved = try XCTUnwrap(store.loadAll().first)
        XCTAssertEqual(moved.folderPath, ["New"])
        // ... and the feed republished so the list reflects the move.
        XCTAssertEqual(feed.thoughts.first?.folderPath, ["New"])
    }

    func testRenameToTakenSiblingReturnsNilAndDoesNotClobber() async throws {
        try store.save(thought("in old", folder: ["Old"]))
        try store.save(thought("in taken", folder: ["Taken"]))
        await feed.start()

        let applied = await feed.renameFolder(at: ["Old"], to: "Taken")

        // A conflict returns nil (the UI surfaces "already used") and neither folder is destroyed.
        XCTAssertNil(applied)
        XCTAssertTrue(store.folders(at: []).contains("Old"))
        XCTAssertTrue(store.folders(at: []).contains("Taken"))
        XCTAssertEqual(store.loadAll().count, 2)
    }

    func testRenameToInvalidNameReturnsNil() async throws {
        try store.save(thought("in old", folder: ["Old"]))
        await feed.start()

        // A name that sanitizes to empty (a bare separator) is rejected; the folder is untouched.
        let applied = await feed.renameFolder(at: ["Old"], to: "/")
        XCTAssertNil(applied)
        XCTAssertTrue(store.folders(at: []).contains("Old"))
    }
}
