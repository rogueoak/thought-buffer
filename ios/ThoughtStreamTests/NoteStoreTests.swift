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

    /// Regression (spec 0013): editing a foldered note and re-saving through the same path the detail
    /// view uses (`Note.editedCopy` -> `store.save`) must NOT relocate it to the root. Before the fix,
    /// `NoteDetailView.currentNote` dropped `folderPath`, so `save` re-filed every foldered note to the
    /// root on commit.
    func testEditingFolderedNoteKeepsItInFolder() throws {
        let note = Note(title: "In folder", paragraphs: ["Original body."], createdAt: Date(),
                        folderPath: ["Work"])
        _ = try store.save(note)

        // Reload from disk so the note carries the folderPath the store tags on load - exactly what the
        // detail view receives - then edit it the way the view does.
        let loaded = try XCTUnwrap(store.load(id: note.id))
        let edited = loaded.editedCopy(
            paragraphs: ["Original body.", "An added paragraph."],
            hasCustomTitle: false,
            customTitle: loaded.title
        )
        let url = try store.save(edited)

        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Work",
                       "an edited foldered note must stay in its folder, not move to root")
        let reloaded = try XCTUnwrap(store.load(id: note.id))
        XCTAssertEqual(reloaded.folderPath, ["Work"])
        XCTAssertEqual(reloaded.paragraphs, ["Original body.", "An added paragraph."])
        // Exactly one note on disk: the edit did not leave a second copy at the root.
        XCTAssertEqual(store.loadAll().count, 1)
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

    /// createFolder accepts a valid trimmed name and rejects any unsafe one (reject-not-strip): a
    /// name containing a separator or traversal is refused whole, never silently rewritten.
    func testCreateFolderAcceptsValidRejectsUnsafe() throws {
        let name = try XCTUnwrap(try store.createFolder(named: "  Work  ", at: []))
        XCTAssertEqual(name, "Work", "surrounding whitespace trimmed, name kept unchanged")
        XCTAssertTrue(store.folders(at: []).contains("Work"))
        // A name that contains a separator or is a traversal is REJECTED, not stripped.
        XCTAssertNil(try store.createFolder(named: " ../evil/name ", at: []))
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

    /// A path that sanitizes/collapses to the ROOT ([".."], ["."], ["/"]) or is empty must NEVER wipe
    /// the whole tree: deleteFolder is a safe no-op and both a top-level note and a real folder
    /// survive.
    func testDeleteFolderCollapsingPathsAreNoOps() throws {
        let top = Note(title: "top", paragraphs: ["x"], createdAt: Date())
        try store.save(top)
        try store.createFolder(named: "Real", at: [])

        for path in [[".."], ["."], ["/"], []] {
            XCTAssertNoThrow(try store.deleteFolder(at: path))
        }

        // The whole tree is intact.
        XCTAssertNotNil(store.load(id: top.id))
        XCTAssertTrue(store.folders(at: []).contains("Real"))
    }

    /// A rename keyed off a collapsing path ([".."]) returns nil and never moves the whole tree.
    func testRenameFolderCollapsingPathReturnsNilAndTreeIntact() throws {
        let top = Note(title: "top", paragraphs: ["x"], createdAt: Date())
        try store.save(top)
        try store.createFolder(named: "Real", at: [])

        XCTAssertNil(try store.renameFolder(at: [".."], to: "x"))

        XCTAssertNotNil(store.load(id: top.id))
        XCTAssertTrue(store.folders(at: []).contains("Real"))
    }

    /// A case-only rename ("work" -> "Work") succeeds on the case-insensitive volume and preserves
    /// the note inside, rather than being falsely rejected by the clobber guard.
    func testCaseOnlyFolderRenameSucceeds() throws {
        let note = Note(title: "kept", paragraphs: ["Body."], createdAt: Date(), folderPath: ["work"])
        try store.save(note)

        let newName = try XCTUnwrap(try store.renameFolder(at: ["work"], to: "Work"))
        XCTAssertEqual(newName, "Work")

        let all = store.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.title, "kept")
        XCTAssertEqual(all.first?.folderPath.map { $0.lowercased() }, ["work"])
    }

    // MARK: - Recoverable delete (spec 0020)

    /// Soft-delete moves the note out of the tree (it no longer loads) but does NOT destroy it, and
    /// restore brings it back to its original folder with its content intact.
    func testSoftDeleteThenRestoreRoundTrip() throws {
        let note = Note(title: "Recoverable", paragraphs: ["Keep me around."], createdAt: Date(),
                        folderPath: ["Work"])
        try store.save(note)

        let token = try XCTUnwrap(try store.softDelete(id: note.id))
        XCTAssertEqual(token.id, note.id)
        XCTAssertEqual(token.formerFolderPath, ["Work"])
        XCTAssertNil(token.audioFilename, "no recording, so no audio filename")
        // Gone from the visible tree.
        XCTAssertNil(store.load(id: note.id))
        XCTAssertEqual(store.loadAll().count, 0)

        let restored = try store.restore(token)
        XCTAssertEqual(restored.folderPath, ["Work"])
        XCTAssertFalse(restored.landedAtRoot)
        let back = try XCTUnwrap(store.load(id: note.id))
        XCTAssertEqual(back.folderPath, ["Work"])
        XCTAssertEqual(back.paragraphs, ["Keep me around."])
    }

    /// The audio SIBLING is moved into the trash on soft-delete and moved back on restore, so an undo
    /// fully recovers a recorded note.
    func testSoftDeleteAndRestoreMovesAudioSibling() throws {
        let id = UUID()
        let note = Note(id: id, title: "Rec", paragraphs: ["Body."], createdAt: Date(),
                        folderPath: ["Voice"])
        try store.save(note)
        try store.saveAudio(from: makeTempRecording(), for: id)
        XCTAssertTrue(store.audioExists(for: id))

        let token = try XCTUnwrap(try store.softDelete(id: id))
        XCTAssertEqual(token.audioFilename, "\(id.uuidString).m4a")
        XCTAssertFalse(store.audioExists(for: id), "audio moved to trash, not beside a live note")

        _ = try store.restore(token)
        XCTAssertNotNil(store.load(id: id))
        let resolved = try XCTUnwrap(store.audioURL(for: id))
        XCTAssertEqual(resolved.deletingLastPathComponent().lastPathComponent, "Voice")
        XCTAssertTrue(store.audioExists(for: id), "audio restored beside the note")
    }

    /// Restoring a note whose original folder was deleted meanwhile lands it at ROOT (never a failure),
    /// and the result records that it landed at root.
    func testRestoreWhenOriginalFolderGoneLandsAtRoot() throws {
        let note = Note(title: "Orphan", paragraphs: ["Body."], createdAt: Date(), folderPath: ["Temp"])
        try store.save(note)
        let token = try XCTUnwrap(try store.softDelete(id: note.id))

        // The folder is gone (empty after the note left, then removed by the user).
        try store.deleteFolder(at: ["Temp"])
        XCTAssertFalse(store.folders(at: []).contains("Temp"))

        let restored = try store.restore(token)
        XCTAssertTrue(restored.landedAtRoot)
        XCTAssertEqual(restored.folderPath, [])
        let back = try XCTUnwrap(store.load(id: note.id))
        XCTAssertEqual(back.folderPath, [], "restored to root because the original folder was gone")
    }

    /// Purge permanently removes a trashed note: after purge, restore recovers nothing.
    func testPurgeRemovesTrashedNotePermanently() throws {
        let note = Note(title: "Doomed", paragraphs: ["Body."], createdAt: Date())
        try store.save(note)
        let token = try XCTUnwrap(try store.softDelete(id: note.id))

        try store.purge(token)
        _ = try store.restore(token) // no-op now: files are gone
        XCTAssertNil(store.load(id: note.id))
    }

    /// purgeAllTrash empties every trashed note (the launch sweep), and never touches live notes.
    func testPurgeAllTrashEmptiesTrashKeepingLiveNotes() throws {
        let live = Note(title: "Alive", paragraphs: ["Here."], createdAt: Date())
        let gone = Note(title: "Trashed", paragraphs: ["Bye."], createdAt: Date())
        try store.save(live)
        try store.save(gone)
        let token = try XCTUnwrap(try store.softDelete(id: gone.id))

        try store.purgeAllTrash()
        _ = try store.restore(token) // nothing to bring back
        XCTAssertNil(store.load(id: gone.id))
        XCTAssertNotNil(store.load(id: live.id), "the live note is untouched by the trash sweep")
    }

    /// The trash NEVER escapes the store root: the trashed files sit under `.trash/` inside the store
    /// directory, and a soft-deleted note is not visible to `loadAll` (which skips the hidden dir).
    func testTrashStaysInsideStoreRoot() throws {
        let note = Note(title: "x", paragraphs: ["Body."], createdAt: Date())
        try store.save(note)
        _ = try XCTUnwrap(try store.softDelete(id: note.id))

        // The trashed file lives under <root>/.trash/<id>/<id>.md - strictly inside the root.
        let trashDir = tempDir.appendingPathComponent(".trash", isDirectory: true)
            .appendingPathComponent(note.id.uuidString, isDirectory: true)
        let trashedNote = trashDir.appendingPathComponent("\(note.id.uuidString).md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashedNote.path),
                      "trashed file must sit under <root>/.trash/, inside the store root")
        XCTAssertTrue(trashedNote.standardizedFileURL.path.hasPrefix(tempDir.standardizedFileURL.path + "/"),
                      "trash path must never escape the store root")
        // Hidden trash is not surfaced as a note.
        XCTAssertEqual(store.loadAll().count, 0)
    }

    /// Soft-deleting a missing note returns nil (nothing to trash), not a throw.
    func testSoftDeleteMissingReturnsNil() throws {
        XCTAssertNil(try store.softDelete(id: UUID()))
    }

    /// Purge removes EXACTLY the targeted note, leaving a second trashed note still restorable - so a
    /// commit of one undo window never destroys another pending delete's trash.
    func testPurgeRemovesOnlyTheTargetedTrashedNote() throws {
        let keep = Note(title: "Keep trashed", paragraphs: ["Recoverable."], createdAt: Date())
        let drop = Note(title: "Drop trashed", paragraphs: ["Doomed."], createdAt: Date())
        try store.save(keep)
        try store.save(drop)
        let keepToken = try XCTUnwrap(try store.softDelete(id: keep.id))
        let dropToken = try XCTUnwrap(try store.softDelete(id: drop.id))

        try store.purge(dropToken)

        // The other trashed note is untouched and still restorable.
        let restored = try store.restore(keepToken)
        XCTAssertFalse(restored.landedAtRoot)
        XCTAssertNotNil(store.load(id: keep.id), "purging one note must not destroy another's trash")
        // The purged one is gone for good.
        _ = try store.restore(dropToken)
        XCTAssertNil(store.load(id: drop.id))
    }

    /// A failing AUDIO move during soft-delete ROLLS BACK the note move: the note ends up fully in place
    /// (still loadable, with its audio), the function throws, and NO token is returned - so the note is
    /// never half-in-trash-with-no-undo where the launch sweep could destroy it.
    func testSoftDeleteRollsBackNoteMoveWhenAudioMoveFails() throws {
        let id = UUID()
        let note = Note(id: id, title: "Atomic", paragraphs: ["Body."], createdAt: Date())
        let noteURL = try store.save(note)
        let audioURL = try store.saveAudio(from: makeTempRecording(), for: id)

        // Make the audio file immutable so the store's move of it fails (EPERM), while the note file
        // moves fine - exercising the partial-failure path.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: audioURL.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: audioURL.path) }

        XCTAssertThrowsError(try store.softDelete(id: id), "a failed audio move must surface, not swallow")

        // Rolled back: both files are back in place and the note still loads with its recording.
        XCTAssertTrue(FileManager.default.fileExists(atPath: noteURL.path),
                      "the note file must be rolled back into place, not left in trash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertNotNil(store.load(id: id))
        XCTAssertEqual(store.loadAll().count, 1, "the note is still listed after a rolled-back delete")
        XCTAssertTrue(store.audioExists(for: id))
    }

    /// Write a stand-in recording to a temp file the store will move into place.
    private func makeTempRecording(content: String = "audio-bytes") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).m4a")
        try Data(content.utf8).write(to: url)
        return url
    }
}
