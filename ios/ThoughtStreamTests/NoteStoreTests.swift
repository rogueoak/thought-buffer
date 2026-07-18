import XCTest
@testable import ThoughtStream

/// NoteStore file persistence: save/load round-trip, sorting, delete, tolerant load.
final class NoteStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: NoteStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = NoteStore(directory: tempDir)
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

    func testSaveLoadRoundTrip() throws {
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
        let old = Note(title: "old", paragraphs: ["Old."],
                       createdAt: Date(timeIntervalSince1970: 1_000))
        let mid = Note(title: "mid", paragraphs: ["Mid."],
                       createdAt: Date(timeIntervalSince1970: 2_000))
        let new = Note(title: "new", paragraphs: ["New."],
                       createdAt: Date(timeIntervalSince1970: 3_000))

        try store.save(old)
        try store.save(new)
        try store.save(mid)

        let all = store.loadAll()
        XCTAssertEqual(all.map(\.title), ["new", "mid", "old"])
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
        // Drop a stray file that is not a note.
        try "not a note".write(
            to: tempDir.appendingPathComponent("readme.txt"),
            atomically: true, encoding: .utf8
        )

        let all = store.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.title, "keep")
    }

    // MARK: - Folders (spec 0010)

    /// A note saved with a folderPath writes into that subdirectory and loads back with the same
    /// folderPath. This is the round-trip the acceptance criteria calls for.
    func testFolderRoundTrip() throws {
        let note = Note(title: "Filed", paragraphs: ["In a folder."], createdAt: Date(),
                        folderPath: ["Work"])
        let url = try store.save(note)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Work")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let loaded = try XCTUnwrap(store.load(id: note.id))
        XCTAssertEqual(loaded.folderPath, ["Work"])
        XCTAssertEqual(loaded.paragraphs, note.paragraphs)

        let all = store.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.folderPath, ["Work"])
    }

    /// The Markdown bytes of a foldered note are IDENTICAL to a top-level note's: the folder is the
    /// file's location, never a frontmatter key (spec 0010 acceptance).
    func testFolderedNoteMarkdownBytesIdenticalToTopLevel() throws {
        let id = UUID()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let top = Note(id: id, title: "Same", paragraphs: ["Body text."], createdAt: created,
                       folderPath: [])
        let filed = Note(id: id, title: "Same", paragraphs: ["Body text."], createdAt: created,
                         folderPath: ["Work", "Q3"])
        XCTAssertEqual(top.markdown, filed.markdown, "folder is a location, not a frontmatter key")

        // And prove it on disk: the bytes written for the foldered note equal the top-level bytes.
        let url = try store.save(filed)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(onDisk, top.markdown)
    }

    /// Nested folders (two levels) round-trip: the note lands at directory/A/B/<id>.md and loads
    /// with folderPath == [A, B].
    func testNestedFolderRoundTrip() throws {
        let note = Note(title: "Deep", paragraphs: ["Nested."], createdAt: Date(),
                        folderPath: ["Projects", "2026"])
        let url = try store.save(note)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "2026")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "Projects")

        let loaded = try XCTUnwrap(store.load(id: note.id))
        XCTAssertEqual(loaded.folderPath, ["Projects", "2026"])
    }

    /// Saving a note with a changed folderPath MOVES its `.md` and `.m4a` and leaves nothing behind
    /// in the old location (spec 0010 acceptance).
    func testSaveWithChangedFolderMovesMarkdownAndAudioLeavingNothing() throws {
        let id = UUID()
        let original = Note(id: id, title: "Move me", paragraphs: ["Body."], createdAt: Date(),
                            audioFileName: "\(id.uuidString).m4a",
                            timings: [ParagraphTiming(start: 0, duration: 1)],
                            folderPath: ["Inbox"])
        let firstURL = try store.save(original)
        try store.saveAudio(from: makeTempRecording(), for: id)
        let oldAudio = firstURL.deletingLastPathComponent()
            .appendingPathComponent("\(id.uuidString).m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldAudio.path))

        // Re-save with a new folder: this is the move.
        let moved = original.withFolderPath(["Archive"])
        let newURL = try store.save(moved)
        let newAudio = newURL.deletingLastPathComponent()
            .appendingPathComponent("\(id.uuidString).m4a")

        // New location has both files.
        XCTAssertEqual(newURL.deletingLastPathComponent().lastPathComponent, "Archive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newAudio.path))
        // Old location has NOTHING left behind.
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldAudio.path))

        // And the note loads from the new folder.
        XCTAssertEqual(store.load(id: id)?.folderPath, ["Archive"])
    }

    /// Audio placed beside a note in a subfolder resolves through the id-only audioURL (which scans
    /// the tree), so recorded playback still works after filing.
    func testAudioInSubfolderResolves() throws {
        let id = UUID()
        let note = Note(id: id, title: "Rec", paragraphs: ["Body."], createdAt: Date(),
                        folderPath: ["Voice"])
        try store.save(note)
        try store.saveAudio(from: makeTempRecording(), for: id)

        let resolved = try XCTUnwrap(store.audioURL(for: id))
        XCTAssertEqual(resolved.deletingLastPathComponent().lastPathComponent, "Voice")
        XCTAssertTrue(store.audioExists(for: id))
    }

    /// Deleting a note in a subfolder removes its `.md` and its sibling `.m4a` from that subfolder.
    func testDeleteLocatesNoteAndAudioInSubfolder() throws {
        let id = UUID()
        let note = Note(id: id, title: "Gone", paragraphs: ["Body."], createdAt: Date(),
                        folderPath: ["Trashy"])
        let url = try store.save(note)
        try store.saveAudio(from: makeTempRecording(), for: id)
        let audio = url.deletingLastPathComponent().appendingPathComponent("\(id.uuidString).m4a")

        try store.delete(id: id)
        XCTAssertNil(store.load(id: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    /// `folders(at:)` lists child folders at a path, sorted A-Z, and only directories (not notes).
    func testFoldersListsChildDirectories() throws {
        try store.createFolder(named: "Work", at: [])
        try store.createFolder(named: "Archive", at: [])
        try store.save(Note(title: "top", paragraphs: ["x"], createdAt: Date()))
        // A subfolder under Work should not appear at the top level.
        try store.createFolder(named: "Q3", at: ["Work"])

        XCTAssertEqual(store.folders(at: []), ["Archive", "Work"])
        XCTAssertEqual(store.folders(at: ["Work"]), ["Q3"])
    }

    /// createFolder sanitizes the name and rejects one that sanitizes to empty.
    func testCreateFolderSanitizesAndRejectsEmpty() throws {
        let name = try XCTUnwrap(try store.createFolder(named: " ../evil/name ", at: []))
        XCTAssertEqual(name, "evilname", "separators and leading dots stripped")
        XCTAssertTrue(store.folders(at: []).contains("evilname"))
        // A name that is only dots/separators sanitizes to empty and is rejected.
        XCTAssertNil(try store.createFolder(named: "..", at: []))
    }

    /// renameFolder keeps the notes inside it (they move with the directory).
    func testRenameFolderKeepsNotes() throws {
        let note = Note(title: "kept", paragraphs: ["Body."], createdAt: Date(), folderPath: ["Old"])
        try store.save(note)

        let newName = try XCTUnwrap(try store.renameFolder(at: ["Old"], to: "New"))
        XCTAssertEqual(newName, "New")
        XCTAssertFalse(store.folders(at: []).contains("Old"))
        XCTAssertTrue(store.folders(at: []).contains("New"))

        let all = store.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.title, "kept")
        XCTAssertEqual(all.first?.folderPath, ["New"])
    }

    /// renameFolder onto an existing sibling name is REJECTED, not a clobber: both folders and all
    /// their notes survive (a rename must never delete another folder's contents).
    func testRenameFolderOntoExistingNameIsRejected() throws {
        try store.save(Note(title: "in old", paragraphs: ["A."], createdAt: Date(), folderPath: ["Old"]))
        try store.save(Note(title: "in taken", paragraphs: ["B."], createdAt: Date(), folderPath: ["Taken"]))

        XCTAssertNil(try store.renameFolder(at: ["Old"], to: "Taken"),
                     "rename onto an existing folder must be rejected")

        // Both folders and both notes still exist.
        XCTAssertTrue(store.folders(at: []).contains("Old"))
        XCTAssertTrue(store.folders(at: []).contains("Taken"))
        let titles = Set(store.loadAll().map(\.title))
        XCTAssertEqual(titles, ["in old", "in taken"])
    }

    /// deleteFolder cascades: notes, their recordings, and subfolders all go.
    func testDeleteFolderCascades() throws {
        let n1 = Note(title: "a", paragraphs: ["x"], createdAt: Date(), folderPath: ["Doomed"])
        let n2 = Note(title: "b", paragraphs: ["y"], createdAt: Date(), folderPath: ["Doomed", "Sub"])
        try store.save(n1)
        try store.save(n2)
        try store.saveAudio(from: makeTempRecording(), for: n1.id)
        try store.saveAudio(from: makeTempRecording(), for: n2.id)
        // A note outside the folder must survive.
        let survivor = Note(title: "safe", paragraphs: ["z"], createdAt: Date())
        try store.save(survivor)

        try store.deleteFolder(at: ["Doomed"])

        XCTAssertNil(store.load(id: n1.id))
        XCTAssertNil(store.load(id: n2.id))
        XCTAssertFalse(store.audioExists(for: n1.id))
        XCTAssertFalse(store.audioExists(for: n2.id))
        XCTAssertFalse(store.folders(at: []).contains("Doomed"))
        // The outside note survives.
        XCTAssertNotNil(store.load(id: survivor.id))
    }

    func testDeleteFolderMissingIsNoOp() {
        XCTAssertNoThrow(try store.deleteFolder(at: ["Nope"]))
    }

    /// Write a stand-in recording to a temp file the store will move into place.
    private func makeTempRecording(content: String = "audio-bytes") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).m4a")
        try Data(content.utf8).write(to: url)
        return url
    }
}
