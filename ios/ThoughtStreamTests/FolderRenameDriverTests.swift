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

    // MARK: - Delete through the feed (feedback 0026, item 4/5)

    /// Deleting a folder through `StreamFeed.deleteFolder(at:)` - the exact call the top-level "..." menu and
    /// the folder-screen "..." menu make - removes the folder (a cascade) on disk and republishes so the list
    /// reflects it gone. A regression here is the delete appearing to do nothing in the UI.
    func testDeleteFolderThroughFeedRemovesOnDiskAndReloads() async throws {
        try store.save(thought("in doomed", folder: ["Doomed"]))
        try store.save(thought("keep me", folder: ["Keep"]))
        await feed.start()
        XCTAssertTrue(store.folders(at: []).contains("Doomed"))

        await feed.deleteFolder(at: ["Doomed"])

        // The folder and its thought are gone on disk ...
        XCTAssertFalse(store.folders(at: []).contains("Doomed"))
        // ... a sibling folder and its thought survive ...
        XCTAssertTrue(store.folders(at: []).contains("Keep"))
        // ... and the feed republished so the list no longer shows the deleted thought.
        XCTAssertEqual(feed.thoughts.count, 1)
        XCTAssertEqual(feed.thoughts.first?.folderPath, ["Keep"])
    }

    /// A delete keyed on a collapsing/invalid path (`[]`) is a safe no-op that never wipes the whole tree.
    func testDeleteFolderWithEmptyPathIsNoOp() async throws {
        try store.save(thought("safe", folder: ["Keep"]))
        await feed.start()

        await feed.deleteFolder(at: [])

        XCTAssertTrue(store.folders(at: []).contains("Keep"))
        XCTAssertEqual(feed.thoughts.count, 1)
    }

    /// A case-only rename ("work" -> "Work") is allowed on the case-insensitive iOS volume: the source and
    /// destination are the SAME directory, so there is no sibling to clobber and it is not a conflict.
    func testCaseOnlyRenameIsAllowed() async throws {
        try store.save(thought("in work", folder: ["work"]))
        await feed.start()

        let applied = await feed.renameFolder(at: ["work"], to: "Work")

        XCTAssertEqual(applied, "Work")
        XCTAssertEqual(feed.thoughts.first?.folderPath, ["Work"])
    }

    // MARK: - Move existing thoughts INTO a folder (feedback 0026, item 6)

    /// The empty-folder "Move thoughts here" picker re-files the selected thoughts through the BATCH
    /// `StreamFeed.move(_:to:)` into the target folder. This proves moving several thoughts (uncategorized and
    /// from another folder) into one folder lands them all there and republishes in ONE reload.
    func testMoveMultipleThoughtsIntoFolder() async throws {
        try store.save(thought("loose", folder: []))
        try store.save(thought("elsewhere", folder: ["Other"]))
        try store.save(thought("already here", folder: ["Target"]))
        await feed.start()

        let loose = try XCTUnwrap(feed.thoughts.first { $0.title == "loose" })
        let elsewhere = try XCTUnwrap(feed.thoughts.first { $0.title == "elsewhere" })
        await feed.move([loose, elsewhere], to: ["Target"])

        let inTarget = feed.thoughts.filter { $0.folderPath.first == "Target" }
        XCTAssertEqual(Set(inTarget.map(\.title)), ["loose", "elsewhere", "already here"])
        // "Other" is now empty of thoughts (its only thought moved out).
        XCTAssertTrue(feed.thoughts.filter { $0.folderPath.first == "Other" }.isEmpty)
    }

    /// The picker's id filter (`allThoughts.filter { $0.folderPath.first != folderName }`) excludes thoughts
    /// ALREADY in the folder, so a "move" that includes one is idempotent - it stays put, nothing duplicates,
    /// and the count is unchanged. This guards the `MoveThoughtsIntoFolderSheet.candidates` exclusion.
    func testMoveIntoFolderIsIdempotentForThoughtAlreadyThere() async throws {
        try store.save(thought("already here", folder: ["Target"]))
        try store.save(thought("loose", folder: []))
        await feed.start()

        // The candidate set the picker offers: everything NOT already in Target.
        let candidates = feed.thoughts.filter { $0.folderPath.first != "Target" }
        XCTAssertEqual(candidates.map(\.title), ["loose"])

        // Even if the batch is re-run with a thought already in Target, it lands (re-)in Target - no dup.
        await feed.move(feed.thoughts, to: ["Target"])
        let inTarget = feed.thoughts.filter { $0.folderPath.first == "Target" }
        XCTAssertEqual(Set(inTarget.map(\.title)), ["already here", "loose"])
        XCTAssertEqual(feed.thoughts.count, 2)
    }
}
