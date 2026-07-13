import XCTest
@testable import ThoughtStream

/// Coordinated (NSFileCoordinator) save/load/delete round-trip for ICloudNoteStore, exercised
/// against a temp directory (no real iCloud). Proves the store honors the NoteStoring contract
/// the same way NoteStore does, so either backend is interchangeable behind the seam.
final class ICloudNoteStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: ICloudNoteStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ICloudNoteStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = ICloudNoteStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    func testSaveCreatesDirectoryAndFile() throws {
        let note = Note(title: "x", paragraphs: ["Hello."], createdAt: Date())
        let url = try store.save(note)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.lastPathComponent, "\(note.id.uuidString).md")
    }

    func testCoordinatedSaveLoadRoundTrip() throws {
        let note = Note(
            title: "Launch email",
            paragraphs: ["Open with the story.", "Keep it to three paragraphs."],
            createdAt: Date(timeIntervalSince1970: 1_600_000_000)
        )
        try store.save(note)

        let loaded = try XCTUnwrap(store.load(id: note.id))
        XCTAssertEqual(loaded.id, note.id)
        XCTAssertEqual(loaded.title, note.title)
        XCTAssertEqual(loaded.paragraphs, note.paragraphs)
    }

    func testLoadAllSortsNewestFirst() throws {
        let old = Note(title: "old", paragraphs: ["Old."], createdAt: Date(timeIntervalSince1970: 1_000))
        let mid = Note(title: "mid", paragraphs: ["Mid."], createdAt: Date(timeIntervalSince1970: 2_000))
        let new = Note(title: "new", paragraphs: ["New."], createdAt: Date(timeIntervalSince1970: 3_000))

        try store.save(old)
        try store.save(new)
        try store.save(mid)

        XCTAssertEqual(store.loadAll().map(\.title), ["new", "mid", "old"])
    }

    func testLoadAllEmptyDirectory() {
        XCTAssertEqual(store.loadAll().count, 0)
    }

    func testDeleteRemovesFile() throws {
        let note = Note(title: "x", paragraphs: ["Bye."], createdAt: Date())
        try store.save(note)
        XCTAssertNotNil(store.load(id: note.id))

        try store.delete(id: note.id)
        XCTAssertNil(store.load(id: note.id))
    }

    func testDeleteMissingIsNoOp() throws {
        XCTAssertNoThrow(try store.delete(id: UUID()))
    }

    func testLoadAllSkipsNonMarkdownFiles() throws {
        try store.ensureDirectory()
        let note = Note(title: "keep", paragraphs: ["Keep me."], createdAt: Date())
        try store.save(note)
        try "not a note".write(
            to: tempDir.appendingPathComponent("readme.txt"),
            atomically: true, encoding: .utf8
        )

        let all = store.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.title, "keep")
    }

    /// A file written by the local NoteStore must load through the iCloud store and vice versa,
    /// since both share Note's Markdown serialization. This is what makes the backends
    /// interchangeable and switching lossless.
    func testFileWrittenByLocalStoreLoadsThroughICloudStore() throws {
        let local = NoteStore(directory: tempDir)
        let note = Note(title: "shared", paragraphs: ["Same file, either store."], createdAt: Date())
        try local.save(note)

        let loaded = try XCTUnwrap(store.load(id: note.id))
        XCTAssertEqual(loaded.title, "shared")
        XCTAssertEqual(loaded.paragraphs, note.paragraphs)
    }

    /// The container-rooted initializer nests notes under Documents/ThoughtStream.
    func testContainerDocumentsInitNestsUnderThoughtStream() {
        let documents = tempDir.appendingPathComponent("Documents", isDirectory: true)
        let containerStore = ICloudNoteStore(containerDocumentsURL: documents)
        XCTAssertEqual(containerStore.directory.lastPathComponent, "ThoughtStream")
        XCTAssertEqual(containerStore.directory.deletingLastPathComponent().lastPathComponent, "Documents")
    }
}
