import XCTest
@testable import ThoughtBuffer

/// Coordinated (NSFileCoordinator) save/load/delete round-trip for ICloudThoughtStore, exercised
/// against a temp directory (no real iCloud). Proves the store honors the ThoughtStoring contract
/// the same way ThoughtStore does, so either backend is interchangeable behind the seam.
final class ICloudThoughtStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: ICloudThoughtStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ICloudThoughtStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = ICloudThoughtStore.forTesting(directory: tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    func testSaveCreatesDirectoryAndFile() throws {
        let thought = Thought(title: "x", paragraphs: ["Hello."], createdAt: Date())
        let url = try store.save(thought)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.lastPathComponent, "\(thought.id.uuidString).md")
    }

    func testCoordinatedSaveLoadRoundTrip() throws {
        let thought = Thought(
            title: "Launch email",
            paragraphs: ["Open with the story.", "Keep it to three paragraphs."],
            createdAt: Date(timeIntervalSince1970: 1_600_000_000)
        )
        try store.save(thought)

        let loaded = try XCTUnwrap(store.load(id: thought.id))
        XCTAssertEqual(loaded.id, thought.id)
        XCTAssertEqual(loaded.title, thought.title)
        XCTAssertEqual(loaded.paragraphs, thought.paragraphs)
        // Pin the ISO8601 frontmatter date round-trip directly, not just via sort order.
        XCTAssertEqual(loaded.createdAt.timeIntervalSince1970, thought.createdAt.timeIntervalSince1970, accuracy: 0.001)
    }

    /// A bare `.md` file with no frontmatter - as a thought synced in from another device or edited
    /// by hand might be - loads with its id derived from the filename and its date from the file's
    /// modification time (the fallbackID / fallbackDate path in `readThought`).
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
        let old = Thought(title: "old", paragraphs: ["Old."], createdAt: Date(timeIntervalSince1970: 1_000))
        let mid = Thought(title: "mid", paragraphs: ["Mid."], createdAt: Date(timeIntervalSince1970: 2_000))
        let new = Thought(title: "new", paragraphs: ["New."], createdAt: Date(timeIntervalSince1970: 3_000))

        try store.save(old)
        try store.save(new)
        try store.save(mid)

        XCTAssertEqual(store.loadAll().map(\.title), ["new", "mid", "old"])
    }

    func testLoadAllEmptyDirectory() {
        XCTAssertEqual(store.loadAll().count, 0)
    }

    func testDeleteRemovesFile() throws {
        let thought = Thought(title: "x", paragraphs: ["Bye."], createdAt: Date())
        try store.save(thought)
        XCTAssertNotNil(store.load(id: thought.id))

        try store.delete(id: thought.id)
        XCTAssertNil(store.load(id: thought.id))
    }

    func testDeleteMissingIsNoOp() throws {
        XCTAssertNoThrow(try store.delete(id: UUID()))
    }

    func testLoadAllSkipsNonMarkdownFiles() throws {
        try store.ensureDirectory()
        let thought = Thought(title: "keep", paragraphs: ["Keep me."], createdAt: Date())
        try store.save(thought)
        try "not a thought".write(
            to: tempDir.appendingPathComponent("readme.txt"),
            atomically: true, encoding: .utf8
        )

        let all = store.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.title, "keep")
    }

    /// A file written by the local ThoughtStore must load through the iCloud store and vice versa,
    /// since both share Thought's Markdown serialization. This is what makes the backends
    /// interchangeable and switching lossless.
    func testFileWrittenByLocalStoreLoadsThroughICloudStore() throws {
        let local = ThoughtStore(directory: tempDir)
        let thought = Thought(title: "shared", paragraphs: ["Same file, either store."], createdAt: Date())
        try local.save(thought)

        let loaded = try XCTUnwrap(store.load(id: thought.id))
        XCTAssertEqual(loaded.title, "shared")
        XCTAssertEqual(loaded.paragraphs, thought.paragraphs)
    }

    /// The other direction: a file written by the iCloud store must load through the local store,
    /// so falling back from iCloud to local (or reading iCloud-synced files locally) is lossless.
    func testFileWrittenByICloudStoreLoadsThroughLocalStore() throws {
        let thought = Thought(title: "shared", paragraphs: ["Same file, either store."], createdAt: Date())
        try store.save(thought)

        let local = ThoughtStore(directory: tempDir)
        let loaded = try XCTUnwrap(local.load(id: thought.id))
        XCTAssertEqual(loaded.title, "shared")
        XCTAssertEqual(loaded.paragraphs, thought.paragraphs)
    }

    /// The container-rooted initializer nests thoughts under Documents/ThoughtBuffer.
    func testContainerDocumentsInitNestsUnderThoughtBuffer() {
        let documents = tempDir.appendingPathComponent("Documents", isDirectory: true)
        let containerStore = ICloudThoughtStore(containerDocumentsURL: documents)
        XCTAssertEqual(containerStore.directory.lastPathComponent, "ThoughtBuffer")
        XCTAssertEqual(containerStore.directory.deletingLastPathComponent().lastPathComponent, "Documents")
    }

    // MARK: - Folders (spec 0010), coordinated

    /// A thought saved with a folderPath through the coordinated store writes into that subdirectory and
    /// loads back with the same folderPath.
    func testCoordinatedFolderRoundTrip() throws {
        let thought = Thought(title: "Filed", paragraphs: ["In a folder."], createdAt: Date(),
                        folderPath: ["Work", "Q3"])
        let url = try store.save(thought)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Q3")

        let loaded = try XCTUnwrap(store.load(id: thought.id))
        XCTAssertEqual(loaded.folderPath, ["Work", "Q3"])
        XCTAssertEqual(store.loadAll().first?.folderPath, ["Work", "Q3"])
    }

    /// Saving through the coordinated store with a changed folderPath moves the `.md` and `.m4a` and
    /// leaves nothing behind - the same move invariant as the local store, coordinated.
    func testCoordinatedMoveRelocatesMarkdownAndAudioLeavingNothing() throws {
        let id = UUID()
        let original = Thought(id: id, title: "Move me", paragraphs: ["Body."], createdAt: Date(),
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

    /// deleteFolder cascades through the coordinated store: thoughts, recordings, subfolders.
    func testCoordinatedDeleteFolderCascades() throws {
        let n1 = Thought(title: "a", paragraphs: ["x"], createdAt: Date(), folderPath: ["Doomed"])
        let n2 = Thought(title: "b", paragraphs: ["y"], createdAt: Date(), folderPath: ["Doomed", "Sub"])
        try store.save(n1)
        try store.save(n2)
        try store.saveAudio(from: makeTempRecording(), for: n1.id)
        let survivor = Thought(title: "safe", paragraphs: ["z"], createdAt: Date())
        try store.save(survivor)

        try store.deleteFolder(at: ["Doomed"])

        XCTAssertNil(store.load(id: n1.id))
        XCTAssertNil(store.load(id: n2.id))
        XCTAssertFalse(store.audioExists(for: n1.id))
        XCTAssertFalse(store.folders(at: []).contains("Doomed"))
        XCTAssertNotNil(store.load(id: survivor.id))
    }

    /// renameFolder keeps the thoughts inside it, coordinated.
    func testCoordinatedRenameFolderKeepsThoughts() throws {
        let thought = Thought(title: "kept", paragraphs: ["Body."], createdAt: Date(), folderPath: ["Old"])
        try store.save(thought)

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
    /// both folders and their thoughts survive (mirrors the local store's clobber-guard test).
    func testRenameFolderOntoExistingNameIsRejected() throws {
        try store.save(Thought(title: "in old", paragraphs: ["A."], createdAt: Date(), folderPath: ["Old"]))
        try store.save(Thought(title: "in taken", paragraphs: ["B."], createdAt: Date(), folderPath: ["Taken"]))

        XCTAssertNil(try store.renameFolder(at: ["Old"], to: "Taken"),
                     "rename onto an existing folder must be rejected")

        XCTAssertTrue(store.folders(at: []).contains("Old"))
        XCTAssertTrue(store.folders(at: []).contains("Taken"))
        let titles = Set(store.loadAll().map(\.title))
        XCTAssertEqual(titles, ["in old", "in taken"])
    }

    /// A path that collapses to the ROOT ([".."], ["."], ["/"]) or is empty must never wipe or move
    /// the whole tree through the coordinated store: delete is a no-op and rename returns nil, with a
    /// top-level thought and a real folder both surviving.
    func testCollapsingPathsDoNotAffectWholeTree() throws {
        let top = Thought(title: "top", paragraphs: ["x"], createdAt: Date())
        try store.save(top)
        try store.createFolder(named: "Real", at: [])

        for path in [[".."], ["."], ["/"], []] {
            XCTAssertNoThrow(try store.deleteFolder(at: path))
        }
        XCTAssertNil(try store.renameFolder(at: [".."], to: "x"))

        XCTAssertNotNil(store.load(id: top.id))
        XCTAssertTrue(store.folders(at: []).contains("Real"))
    }

    /// The on-disk Markdown BYTES of a foldered thought written through the iCloud store are identical
    /// to a top-level thought's (folder is a location, not a frontmatter key) - byte-compared on disk.
    func testFolderedThoughtMarkdownBytesIdenticalToTopLevel() throws {
        let id = UUID()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let top = Thought(id: id, title: "Same", paragraphs: ["Body text."], createdAt: created, folderPath: [])
        let filed = Thought(id: UUID(), title: "Same", paragraphs: ["Body text."], createdAt: created,
                         folderPath: ["Work", "Q3"])

        let topURL = try store.save(top)
        let filedURL = try store.save(filed)
        let topBytes = try Data(contentsOf: topURL)
        let filedBytes = try Data(contentsOf: filedURL)
        // Same body/frontmatter modulo the id line: compare the bytes with each thought's id normalized.
        let topText = String(data: topBytes, encoding: .utf8)!
            .replacingOccurrences(of: top.id.uuidString, with: "ID")
        let filedText = String(data: filedBytes, encoding: .utf8)!
            .replacingOccurrences(of: filed.id.uuidString, with: "ID")
        XCTAssertEqual(topText, filedText, "folder is a location, not a frontmatter key")
    }

    /// A recorded thought filed into a subfolder reports audioExists == true via the coordinated tree
    /// walk (audioURL scans the tree, audioExists checks coordinated - not a bare FileManager check).
    func testRecordedThoughtInSubfolderAudioExistsViaCoordinatedWalk() throws {
        let id = UUID()
        let thought = Thought(id: id, title: "Rec", paragraphs: ["Body."], createdAt: Date(), folderPath: ["Voice"])
        try store.save(thought)
        try store.saveAudio(from: makeTempRecording(), for: id)

        let resolved = try XCTUnwrap(store.audioURL(for: id))
        XCTAssertEqual(resolved.deletingLastPathComponent().lastPathComponent, "Voice")
        XCTAssertTrue(store.audioExists(for: id))
    }

    /// A folder created by the local store is visible to the iCloud store and vice versa (shared tree).
    func testFolderTreeSharedBetweenBackends() throws {
        let local = ThoughtStore(directory: tempDir)
        try local.createFolder(named: "Shared", at: [])
        XCTAssertTrue(store.folders(at: []).contains("Shared"))

        try store.createFolder(named: "AlsoShared", at: [])
        XCTAssertTrue(local.folders(at: []).contains("AlsoShared"))
    }

    // MARK: - Recoverable delete (spec 0020)

    /// Coordinated soft-delete then restore round-trips the thought back to its folder with content intact,
    /// including its audio sibling - the same recoverable-delete contract the local store honors.
    func testCoordinatedSoftDeleteRestoreRoundTripWithAudio() throws {
        let id = UUID()
        let thought = Thought(id: id, title: "Rec", paragraphs: ["Body."], createdAt: Date(),
                        folderPath: ["Voice"])
        try store.save(thought)
        try store.saveAudio(from: makeTempRecording(), for: id)

        let token = try XCTUnwrap(try store.softDelete(id: id))
        XCTAssertEqual(token.formerFolderPath, ["Voice"])
        XCTAssertEqual(token.audioFilename, "\(id.uuidString).m4a")
        XCTAssertNil(store.load(id: id))
        XCTAssertFalse(store.audioExists(for: id))

        let restored = try store.restore(token)
        XCTAssertEqual(restored.folderPath, ["Voice"])
        XCTAssertFalse(restored.landedAtRoot)
        XCTAssertNotNil(store.load(id: id))
        XCTAssertTrue(store.audioExists(for: id))
    }

    /// Restore when the original folder is gone lands the thought at root (never a failure), coordinated.
    func testCoordinatedRestoreWhenFolderGoneLandsAtRoot() throws {
        let thought = Thought(title: "Orphan", paragraphs: ["Body."], createdAt: Date(), folderPath: ["Temp"])
        try store.save(thought)
        let token = try XCTUnwrap(try store.softDelete(id: thought.id))
        try store.deleteFolder(at: ["Temp"])

        let restored = try store.restore(token)
        XCTAssertTrue(restored.landedAtRoot)
        XCTAssertEqual(store.load(id: thought.id)?.folderPath, [])
    }

    /// Purge permanently removes the trashed thought, coordinated; and the trash sits inside the store root.
    func testCoordinatedPurgeAndTrashStaysInsideRoot() throws {
        let thought = Thought(title: "Doomed", paragraphs: ["Body."], createdAt: Date())
        try store.save(thought)
        let token = try XCTUnwrap(try store.softDelete(id: thought.id))

        let trashedThought = tempDir.appendingPathComponent(".trash", isDirectory: true)
            .appendingPathComponent(thought.id.uuidString, isDirectory: true)
            .appendingPathComponent("\(thought.id.uuidString).md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashedThought.path))
        XCTAssertTrue(trashedThought.standardizedFileURL.path.hasPrefix(tempDir.standardizedFileURL.path + "/"))
        XCTAssertEqual(store.loadAll().count, 0, "trashed thought is hidden from loadAll")

        try store.purge(token)
        _ = try store.restore(token) // nothing to bring back
        XCTAssertNil(store.load(id: thought.id))
    }

    /// Coordinated purge removes EXACTLY the targeted thought, leaving a second trashed thought restorable.
    func testCoordinatedPurgeRemovesOnlyTheTargetedTrashedThought() throws {
        let keep = Thought(title: "Keep", paragraphs: ["Recoverable."], createdAt: Date())
        let drop = Thought(title: "Drop", paragraphs: ["Doomed."], createdAt: Date())
        try store.save(keep)
        try store.save(drop)
        let keepToken = try XCTUnwrap(try store.softDelete(id: keep.id))
        let dropToken = try XCTUnwrap(try store.softDelete(id: drop.id))

        try store.purge(dropToken)

        _ = try store.restore(keepToken)
        XCTAssertNotNil(store.load(id: keep.id), "purging one thought must not destroy another's trash")
        _ = try store.restore(dropToken)
        XCTAssertNil(store.load(id: drop.id))
    }

    /// A failing AUDIO move during coordinated soft-delete ROLLS BACK the thought move: both files end up in
    /// place, the function throws, and no token is returned - never half-in-trash-with-no-undo.
    func testCoordinatedSoftDeleteRollsBackWhenAudioMoveFails() throws {
        let id = UUID()
        let thought = Thought(id: id, title: "Atomic", paragraphs: ["Body."], createdAt: Date())
        let thoughtURL = try store.save(thought)
        let audioURL = try store.saveAudio(from: makeTempRecording(), for: id)

        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: audioURL.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: audioURL.path) }

        XCTAssertThrowsError(try store.softDelete(id: id))

        XCTAssertTrue(FileManager.default.fileExists(atPath: thoughtURL.path),
                      "the thought file must be rolled back into place, not left in trash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertNotNil(store.load(id: id))
        XCTAssertEqual(store.loadAll().count, 1)
    }

    /// Write a stand-in recording to a temp file the store will move into place.
    private func makeTempRecording(content: String = "audio-bytes") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).m4a")
        try Data(content.utf8).write(to: url)
        return url
    }
}
