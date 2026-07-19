import XCTest
@testable import ThoughtStream

/// The undoable-delete coordinator (`ThoughtDeletionController`, spec 0020), driven over a REAL `ThoughtStore`
/// (temp dir) with a NIL UndoManager - so the delete -> undo / delete -> commit paths, the pending-token
/// lifecycle, and the launch sweep are all provable without the system shake gesture (a manual-verify).
/// With no UndoManager the controller takes its direct restore/purge fallbacks, which is exactly the
/// underlying seam the shake channel also drives.
@MainActor
final class ThoughtDeletionControllerTests: XCTestCase {
    private var tempDir: URL!
    private var store: ThoughtStore!
    private var feed: StreamFeed!
    private var controller: ThoughtDeletionController!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThoughtDeletionControllerTests-\(UUID().uuidString)", isDirectory: true)
        store = ThoughtStore(directory: tempDir)
        feed = StreamFeed(store: store)
        controller = ThoughtDeletionController(feed: feed)
        // No UndoManager: exercise the in-app channel and its direct restore/purge fallbacks.
        controller.undoManager = nil
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    /// The number of `<id>/` entries currently in the store trash - i.e. how many soft-deleted thoughts have
    /// files still on disk. Zero means nothing is stranded.
    private func trashedCount() -> Int {
        let trashRoot = tempDir.appendingPathComponent(".trash", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: trashRoot, includingPropertiesForKeys: nil, options: []) else { return 0 }
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }.count
    }

    /// A delete followed by undo restores the thought to the list.
    func testDeleteThenUndoRestoresThought() async throws {
        let thought = Thought(title: "Recoverable", paragraphs: ["Body."], createdAt: Date())
        try store.save(thought)
        await feed.reload()

        await controller.delete(id: thought.id)
        XCTAssertEqual(feed.thoughts.count, 0)
        XCTAssertNotNil(controller.pending, "the undo window is open after a delete")

        await controller.undo()
        XCTAssertEqual(feed.thoughts.count, 1, "undo restores the thought")
        XCTAssertNil(controller.pending, "undo closes the window")
        XCTAssertEqual(trashedCount(), 0, "restore empties the thought's trash")
    }

    /// A delete followed by committing the window purges the thought permanently (nothing restorable).
    func testDeleteThenCommitWindowPurges() async throws {
        let thought = Thought(title: "Doomed", paragraphs: ["Body."], createdAt: Date())
        try store.save(thought)
        await feed.reload()

        await controller.delete(id: thought.id)
        let token = try XCTUnwrap(controller.pending)

        await controller.commitWindow()
        XCTAssertNil(controller.pending, "commit closes the window")
        XCTAssertEqual(trashedCount(), 0, "commit purges the trashed files")
        // Nothing left to restore.
        await feed.restore(token)
        XCTAssertEqual(feed.thoughts.count, 0)
        XCTAssertNil(store.load(id: thought.id))
    }

    /// commitWindow is idempotent: a second commit with nothing pending is a harmless no-op.
    func testCommitWindowIsIdempotent() async throws {
        let thought = Thought(title: "x", paragraphs: ["Body."], createdAt: Date())
        try store.save(thought)
        await feed.reload()

        await controller.delete(id: thought.id)
        await controller.commitWindow()
        await controller.commitWindow() // no crash, no state change
        XCTAssertNil(controller.pending)
    }

    /// A second delete while a first is pending COMMITS the first (purges its trash) and leaves only the
    /// second pending: exactly one thought is in the trash, so the first's token is never stranded. This is
    /// the reentrancy the fix guards - `delete` captures-and-clears `pending` before its await, so the
    /// second delete does not read and re-purge a stale token, and the first's trash is committed exactly
    /// once. (The deletes are sequential, matching real use: each entry point's Task is a discrete
    /// main-actor event.)
    func testSecondDeleteCommitsFirstAndLeavesOnlyOnePending() async throws {
        let first = Thought(title: "First", paragraphs: ["1."], createdAt: Date())
        let second = Thought(title: "Second", paragraphs: ["2."], createdAt: Date())
        try store.save(first)
        try store.save(second)
        await feed.reload()

        await controller.delete(id: first.id)
        let firstToken = try XCTUnwrap(controller.pending)
        XCTAssertEqual(trashedCount(), 1)

        await controller.delete(id: second.id)
        let pending = try XCTUnwrap(controller.pending)
        XCTAssertNotEqual(pending.id, firstToken.id, "the second delete is now the pending one")
        XCTAssertEqual(trashedCount(), 1, "the first's trash was committed - only the second remains")
        XCTAssertEqual(feed.thoughts.count, 0, "both thoughts left the list")

        // The first is permanently gone; the second is still restorable.
        await feed.restore(firstToken)
        XCTAssertNil(store.load(id: first.id), "the first delete was committed, not recoverable")
        await controller.undo()
        XCTAssertEqual(feed.thoughts.count, 1)
        XCTAssertNotNil(store.load(id: pending.id))
    }

    /// A delete that trashes nothing (a missing thought) opens no window.
    func testDeleteOfMissingThoughtOpensNoWindow() async {
        await controller.delete(id: UUID())
        XCTAssertNil(controller.pending)
    }

    // MARK: - Shake to Undo channel (spec 0021 fix)

    /// With an injected UndoManager - the one `UndoManagerHost` vends to the shake gesture - a delete
    /// REGISTERS an undoable "Delete" action on THAT manager. Before the fix, the controller took its
    /// manager from `@Environment(\.undoManager)`, which is nil in plain SwiftUI, so nothing was ever
    /// registered and a shake found nothing. This proves the action lands on the injected manager.
    func testDeleteRegistersUndoOnInjectedManager() async throws {
        let manager = UndoManager()
        manager.groupsByEvent = false
        controller.undoManager = manager
        let thought = Thought(title: "Shakeable", paragraphs: ["Body."], createdAt: Date())
        try store.save(thought)
        await feed.reload()

        manager.beginUndoGrouping()
        await controller.delete(id: thought.id)
        manager.endUndoGrouping()

        XCTAssertTrue(manager.canUndo, "a delete registers an undoable action on the injected manager")
        XCTAssertEqual(manager.undoActionName, "Delete", "the shake prompt reads 'Undo Delete'")
    }

    // The shake gesture invokes `UndoManager.undo()`, which runs the registered closure that calls
    // `undoDelete`. Calling `UndoManager.undo()` SYNCHRONOUSLY in a unit test corrupts the harness heap
    // (the closure hops onto an async Task that re-registers the redo outside the manager's undoing state,
    // with no run loop to close the group). So the tests below drive the controller's OWN undo/redo seams
    // (`undoDelete`/`redoDelete`) directly WITH the injected manager present - the exact restore +
    // re-registration the closure invokes - proving the shake channel RESTORES (not just registers) and
    // that the redo cycle and the stale-pending leak guard hold. The literal `UndoManager.undo()` call
    // and the physical shake stay a manual-verify.

    /// The shake channel's UNDO restores the thought: driving `undoDelete` (what the manager's registered
    /// closure calls) with the injected manager present restores the deleted thought, clears the pending
    /// window, and re-registers a redo on the manager.
    func testInjectedManagerUndoDeleteRestoresAndArmsRedo() async throws {
        let manager = UndoManager()
        manager.groupsByEvent = false
        controller.undoManager = manager
        let thought = Thought(title: "Restore me", paragraphs: ["Body."], createdAt: Date())
        try store.save(thought)
        await feed.reload()

        manager.beginUndoGrouping()
        await controller.delete(id: thought.id)
        manager.endUndoGrouping()
        let token = try XCTUnwrap(controller.pending)
        XCTAssertEqual(feed.thoughts.count, 0)

        // Drive the exact seam the shake's registered closure runs.
        manager.beginUndoGrouping()
        await controller.undoDelete(token)
        manager.endUndoGrouping()

        XCTAssertEqual(feed.thoughts.count, 1, "the shake undo restores the thought")
        XCTAssertNotNil(store.load(id: thought.id))
        XCTAssertNil(controller.pending, "restoring clears the pending window")
        XCTAssertTrue(manager.canUndo, "a redo (re-delete) is armed after the restore")
    }

    /// The shake channel's REDO re-deletes: after an undo restores the thought, driving `redoDelete` (what
    /// the redo closure calls) soft-deletes it again and re-arms the undo, so a shake redo re-applies the
    /// delete.
    func testInjectedManagerRedoDeleteReDeletes() async throws {
        let manager = UndoManager()
        manager.groupsByEvent = false
        controller.undoManager = manager
        let thought = Thought(title: "Yo-yo", paragraphs: ["Body."], createdAt: Date())
        try store.save(thought)
        await feed.reload()

        manager.beginUndoGrouping()
        await controller.delete(id: thought.id)
        manager.endUndoGrouping()
        let deleted = try XCTUnwrap(controller.pending)

        manager.beginUndoGrouping()
        await controller.undoDelete(deleted)
        manager.endUndoGrouping()
        XCTAssertEqual(feed.thoughts.count, 1)

        // Redo re-deletes.
        manager.beginUndoGrouping()
        await controller.redoDelete(deleted)
        manager.endUndoGrouping()

        XCTAssertEqual(feed.thoughts.count, 0, "the shake redo re-deletes the thought")
        XCTAssertNotNil(controller.pending, "the re-delete opens a fresh undo window")
        XCTAssertEqual(trashedCount(), 1, "exactly one thought is trashed (the re-delete's fresh token)")
    }

    /// The redo's stale-pending leak guard: if a DIFFERENT delete is pending when a redo re-deletes, the
    /// prior pending is committed (purged) first, so its trash is never stranded - the same guard `delete`
    /// uses. Here a redo of thought A runs while thought B is pending; A's re-delete must purge B.
    func testInjectedManagerRedoCommitsPriorPendingBeforeReDeleting() async throws {
        let manager = UndoManager()
        manager.groupsByEvent = false
        controller.undoManager = manager
        let a = Thought(title: "A", paragraphs: ["1."], createdAt: Date())
        let b = Thought(title: "B", paragraphs: ["2."], createdAt: Date())
        try store.save(a)
        try store.save(b)
        await feed.reload()

        // Delete A, then undo A (restored, redo armed for A).
        manager.beginUndoGrouping()
        await controller.delete(id: a.id)
        manager.endUndoGrouping()
        let aToken = try XCTUnwrap(controller.pending)
        manager.beginUndoGrouping()
        await controller.undoDelete(aToken)
        manager.endUndoGrouping()
        XCTAssertNil(controller.pending)

        // Now delete B (B pending), then redo A: A's re-delete must purge B's stale token first.
        manager.beginUndoGrouping()
        await controller.delete(id: b.id)
        manager.endUndoGrouping()
        let bToken = try XCTUnwrap(controller.pending)

        manager.beginUndoGrouping()
        await controller.redoDelete(aToken)
        manager.endUndoGrouping()

        // A is pending again; B was committed (purged), so exactly one thought is trashed and B is gone.
        let pending = try XCTUnwrap(controller.pending)
        XCTAssertEqual(pending.id, a.id, "A is the pending delete after its redo")
        XCTAssertEqual(trashedCount(), 1, "B's stale token was purged, not stranded")
        await feed.restore(bToken)
        XCTAssertNil(store.load(id: b.id), "B's delete was committed, not recoverable")
    }

    /// The launch sweep empties the trash of any leftover (committed-but-unswept / crash) entries.
    func testPurgeOrphanedTrashOnLaunchSweeps() async throws {
        let thought = Thought(title: "Leftover", paragraphs: ["Body."], createdAt: Date())
        try store.save(thought)
        await feed.reload()
        await controller.delete(id: thought.id)
        XCTAssertEqual(trashedCount(), 1)

        await controller.purgeOrphanedTrashOnLaunch()
        XCTAssertEqual(trashedCount(), 0, "the launch sweep empties the trash")
    }
}
