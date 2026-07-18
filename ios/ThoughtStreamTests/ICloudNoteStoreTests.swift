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
        store = ICloudNoteStore.forTesting(directory: tempDir)
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
        // Pin the ISO8601 frontmatter date round-trip directly, not just via sort order.
        XCTAssertEqual(loaded.createdAt.timeIntervalSince1970, note.createdAt.timeIntervalSince1970, accuracy: 0.001)
    }

    /// A bare `.md` file with no frontmatter - as a note synced in from another device or edited
    /// by hand might be - loads with its id derived from the filename and its date from the file's
    /// modification time (the fallbackID / fallbackDate path in `readNote`).
    func testLoadsBareMarkdownUsingFilenameIdAndModifiedDate() throws {
        try store.ensureDirectory()
        let id = UUID()
        let url = tempDir.appendingPathComponent("\(id.uuidString).md", isDirectory: false)
        try "Just a body, no frontmatter.".write(to: url, atomically: true, encoding: .utf8)

        let loaded = try XCTUnwrap(store.load(id: id))
        XCTAssertEqual(loaded.id, id, "id should come from the filename")
        XCTAssertEqual(loaded.paragraphs, ["Just a body, no frontmatter."])
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

    /// The other direction: a file written by the iCloud store must load through the local store,
    /// so falling back from iCloud to local (or reading iCloud-synced files locally) is lossless.
    func testFileWrittenByICloudStoreLoadsThroughLocalStore() throws {
        let note = Note(title: "shared", paragraphs: ["Same file, either store."], createdAt: Date())
        try store.save(note)

        let local = NoteStore(directory: tempDir)
        let loaded = try XCTUnwrap(local.load(id: note.id))
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

    // MARK: - Folders (spec 0010), coordinated

    /// A note saved with a folderPath through the coordinated store writes into that subdirectory and
    /// loads back with the same folderPath.
    func testCoordinatedFolderRoundTrip() throws {
        let note = Note(title: "Filed", paragraphs: ["In a folder."], createdAt: Date(),
                        folderPath: ["Work", "Q3"])
        let url = try store.save(note)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Q3")

        let loaded = try XCTUnwrap(store.load(id: note.id))
        XCTAssertEqual(loaded.folderPath, ["Work", "Q3"])
        XCTAssertEqual(store.loadAll().first?.folderPath, ["Work", "Q3"])
    }

    /// Saving through the coordinated store with a changed folderPath moves the `.md` and `.m4a` and
    /// leaves nothing behind - the same move invariant as the local store, coordinated.
    func testCoordinatedMoveRelocatesMarkdownAndAudioLeavingNothing() throws {
        let id = UUID()
        let original = Note(id: id, title: "Move me", paragraphs: ["Body."], createdAt: Date(),
                            audioFileName: "\(id.uuidString).m4a",
                            timings: [ParagraphTiming(start: 0, duration: 1)],
                            folderPath: ["Inbox"])
        let firstURL = try store.save(original)
        try store.saveAudio(from: makeTempRecording(), for: id)
        let oldAudio = firstURL.deletingLastPathComponent().appendingPathComponent("\(id.uuidString).m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldAudio.path))

        let newURL = try store.save(original.withFolderPath(["Archive"]))
        let newAudio = newURL.deletingLastPathComponent().appendingPathComponent("\(id.uuidString).m4a")

        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newAudio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldAudio.path))
        XCTAssertEqual(store.load(id: id)?.folderPath, ["Archive"])
    }

    /// deleteFolder cascades through the coordinated store: notes, recordings, subfolders.
    func testCoordinatedDeleteFolderCascades() throws {
        let n1 = Note(title: "a", paragraphs: ["x"], createdAt: Date(), folderPath: ["Doomed"])
        let n2 = Note(title: "b", paragraphs: ["y"], createdAt: Date(), folderPath: ["Doomed", "Sub"])
        try store.save(n1)
        try store.save(n2)
        try store.saveAudio(from: makeTempRecording(), for: n1.id)
        let survivor = Note(title: "safe", paragraphs: ["z"], createdAt: Date())
        try store.save(survivor)

        try store.deleteFolder(at: ["Doomed"])

        XCTAssertNil(store.load(id: n1.id))
        XCTAssertNil(store.load(id: n2.id))
        XCTAssertFalse(store.audioExists(for: n1.id))
        XCTAssertFalse(store.folders(at: []).contains("Doomed"))
        XCTAssertNotNil(store.load(id: survivor.id))
    }

    /// renameFolder keeps the notes inside it, coordinated.
    func testCoordinatedRenameFolderKeepsNotes() throws {
        let note = Note(title: "kept", paragraphs: ["Body."], createdAt: Date(), folderPath: ["Old"])
        try store.save(note)

        XCTAssertEqual(try store.renameFolder(at: ["Old"], to: "New"), "New")
        XCTAssertEqual(store.folders(at: []), ["New"])
        XCTAssertEqual(store.loadAll().first?.folderPath, ["New"])
    }

    /// folders(at:) lists child folders sorted A-Z through the coordinated read.
    func testCoordinatedFoldersLists() throws {
        try store.createFolder(named: "Work", at: [])
        try store.createFolder(named: "Archive", at: [])
        XCTAssertEqual(store.folders(at: []), ["Archive", "Work"])
    }

    /// rename onto an existing sibling name is REJECTED through the coordinated store, not a clobber:
    /// both folders and their notes survive (mirrors the local store's clobber-guard test).
    func testRenameFolderOntoExistingNameIsRejected() throws {
        try store.save(Note(title: "in old", paragraphs: ["A."], createdAt: Date(), folderPath: ["Old"]))
        try store.save(Note(title: "in taken", paragraphs: ["B."], createdAt: Date(), folderPath: ["Taken"]))

        XCTAssertNil(try store.renameFolder(at: ["Old"], to: "Taken"),
                     "rename onto an existing folder must be rejected")

        XCTAssertTrue(store.folders(at: []).contains("Old"))
        XCTAssertTrue(store.folders(at: []).contains("Taken"))
        let titles = Set(store.loadAll().map(\.title))
        XCTAssertEqual(titles, ["in old", "in taken"])
    }

    /// A path that collapses to the ROOT ([".."], ["."], ["/"]) or is empty must never wipe or move
    /// the whole tree through the coordinated store: delete is a no-op and rename returns nil, with a
    /// top-level note and a real folder both surviving.
    func testCollapsingPathsDoNotAffectWholeTree() throws {
        let top = Note(title: "top", paragraphs: ["x"], createdAt: Date())
        try store.save(top)
        try store.createFolder(named: "Real", at: [])

        for path in [[".."], ["."], ["/"], []] {
            XCTAssertNoThrow(try store.deleteFolder(at: path))
        }
        XCTAssertNil(try store.renameFolder(at: [".."], to: "x"))

        XCTAssertNotNil(store.load(id: top.id))
        XCTAssertTrue(store.folders(at: []).contains("Real"))
    }

    /// The on-disk Markdown BYTES of a foldered note written through the iCloud store are identical
    /// to a top-level note's (folder is a location, not a frontmatter key) - byte-compared on disk.
    func testFolderedNoteMarkdownBytesIdenticalToTopLevel() throws {
        let id = UUID()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let top = Note(id: id, title: "Same", paragraphs: ["Body text."], createdAt: created, folderPath: [])
        let filed = Note(id: UUID(), title: "Same", paragraphs: ["Body text."], createdAt: created,
                         folderPath: ["Work", "Q3"])

        let topURL = try store.save(top)
        let filedURL = try store.save(filed)
        let topBytes = try Data(contentsOf: topURL)
        let filedBytes = try Data(contentsOf: filedURL)
        // Same body/frontmatter modulo the id line: compare the bytes with each note's id normalized.
        let topText = String(data: topBytes, encoding: .utf8)!
            .replacingOccurrences(of: top.id.uuidString, with: "ID")
        let filedText = String(data: filedBytes, encoding: .utf8)!
            .replacingOccurrences(of: filed.id.uuidString, with: "ID")
        XCTAssertEqual(topText, filedText, "folder is a location, not a frontmatter key")
    }

    /// A recorded note filed into a subfolder reports audioExists == true via the coordinated tree
    /// walk (audioURL scans the tree, audioExists checks coordinated - not a bare FileManager check).
    func testRecordedNoteInSubfolderAudioExistsViaCoordinatedWalk() throws {
        let id = UUID()
        let note = Note(id: id, title: "Rec", paragraphs: ["Body."], createdAt: Date(), folderPath: ["Voice"])
        try store.save(note)
        try store.saveAudio(from: makeTempRecording(), for: id)

        let resolved = try XCTUnwrap(store.audioURL(for: id))
        XCTAssertEqual(resolved.deletingLastPathComponent().lastPathComponent, "Voice")
        XCTAssertTrue(store.audioExists(for: id))
    }

    /// A folder created by the local store is visible to the iCloud store and vice versa (shared tree).
    func testFolderTreeSharedBetweenBackends() throws {
        let local = NoteStore(directory: tempDir)
        try local.createFolder(named: "Shared", at: [])
        XCTAssertTrue(store.folders(at: []).contains("Shared"))

        try store.createFolder(named: "AlsoShared", at: [])
        XCTAssertTrue(local.folders(at: []).contains("AlsoShared"))
    }

    /// Write a stand-in recording to a temp file the store will move into place.
    private func makeTempRecording(content: String = "audio-bytes") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).m4a")
        try Data(content.utf8).write(to: url)
        return url
    }
}
