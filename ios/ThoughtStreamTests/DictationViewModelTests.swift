import XCTest
@testable import ThoughtStream

/// The dictation view model's capture-to-save path, exercised without live audio by injecting
/// finalized text. Proves the flow that the simulator's mic cannot reliably drive: text lands
/// in the note, stopping saves a `.md` file, and it reloads from the store.
@MainActor
final class DictationViewModelTests: XCTestCase {
    private var tempDir: URL!
    private var store: NoteStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationVMTests-\(UUID().uuidString)", isDirectory: true)
        store = NoteStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    func testInjectedTextSavesAndReloads() throws {
        let model = DictationViewModel(store: store)
        model.injectFinalized("Call the supplier before noon.")
        model.injectFinalized("Then draft the launch email.")

        XCTAssertEqual(model.paragraphs.count, 2)

        let note = try XCTUnwrap(try model.finish(), "expected a saved note")
        XCTAssertEqual(note.paragraphs, [
            "Call the supplier before noon.",
            "Then draft the launch email."
        ])
        XCTAssertEqual(note.title, "Call the supplier before noon")

        // The note round-trips through the store, newest first.
        let reloaded = store.loadAll()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.id, note.id)
        XCTAssertEqual(reloaded.first?.paragraphs, note.paragraphs)
    }

    func testResumingCustomTitledNotePreservesTitle() throws {
        // Spec 0009: resuming a note the user titled must keep that title, not re-derive it from the
        // (now longer) body.
        let original = Note(
            title: "My chosen title",
            paragraphs: ["Original body sentence."],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            hasCustomTitle: true
        )
        let model = DictationViewModel(store: store, resuming: original)
        model.injectFinalized("Appended thought.")

        let saved = try XCTUnwrap(try model.finish())
        XCTAssertTrue(saved.hasCustomTitle)
        XCTAssertEqual(saved.title, "My chosen title", "resume must not re-derive over a user title")
    }

    func testResumingDerivedTitleNoteReDerivesFromFirstSentence() throws {
        // A non-custom resumed note DERIVES its title from the body, ignoring the stored title. Seed a
        // stored title that differs from what the body derives to, so this proves re-derivation rather
        // than passing whether the code re-derives or carries the original title over (tester review).
        let original = Note(
            title: "A stale stored title",
            paragraphs: ["The real opening sentence. More detail here."],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let model = DictationViewModel(store: store, resuming: original)
        model.injectFinalized("Appended.")

        let saved = try XCTUnwrap(try model.finish())
        XCTAssertFalse(saved.hasCustomTitle)
        XCTAssertEqual(saved.title, "The real opening sentence",
                       "a non-custom note must re-derive, not carry over the stored title")
    }

    func testResumingFolderedNoteReSavesInSameFolder() throws {
        // Spec 0010: continuing a note that lives in a folder must re-save it in place, not yank it
        // back to the top level.
        let original = Note(
            title: "In work",
            paragraphs: ["Original."],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            folderPath: ["Work"]
        )
        try store.save(original)

        let model = DictationViewModel(store: store, resuming: original)
        model.injectFinalized("Appended.")
        let saved = try XCTUnwrap(try model.finish())

        // The reloaded note is still in Work, with the appended paragraph.
        let reloaded = try XCTUnwrap(store.load(id: saved.id))
        XCTAssertEqual(reloaded.folderPath, ["Work"])
        XCTAssertEqual(reloaded.paragraphs, ["Original.", "Appended."])
        // And only one file exists (no stale copy at the root).
        XCTAssertEqual(store.loadAll().count, 1)
    }

    /// A brand-new session started while browsing a folder files its thought in THAT folder (feedback:
    /// the record action must be contextual). Creating from path ["Work", "Q1"] yields a thought whose
    /// `folderPath` is ["Work", "Q1"], not the root.
    func testNewSessionInFolderFilesThoughtThere() throws {
        let model = DictationViewModel(store: store, folderPath: ["Work", "Q1"])
        model.injectFinalized("A thought recorded inside a folder.")

        let saved = try XCTUnwrap(try model.finish())
        XCTAssertEqual(saved.folderPath, ["Work", "Q1"])

        // It really lands in that folder on disk, not the root.
        let reloaded = try XCTUnwrap(store.load(id: saved.id))
        XCTAssertEqual(reloaded.folderPath, ["Work", "Q1"])
    }

    /// The default (no folder) still files at the root, so a session from the root list or a hands-free
    /// entry point (Siri/CarPlay, which pass no folder) is unchanged.
    func testNewSessionWithNoFolderFilesAtRoot() throws {
        let model = DictationViewModel(store: store)
        model.injectFinalized("A top-level thought.")
        let saved = try XCTUnwrap(try model.finish())
        XCTAssertEqual(saved.folderPath, [])
    }

    func testFinishWithNothingCapturedSavesNothing() throws {
        let model = DictationViewModel(store: store)
        XCTAssertNil(try model.finish())
        XCTAssertEqual(store.loadAll().count, 0)
    }

    // MARK: - Save failure is surfaced, not swallowed

    func testFinishThrowsWhenStoreFails() {
        let failing = ThrowingNoteStore()
        let model = DictationViewModel(store: failing)
        model.injectFinalized("A note that cannot be saved.")

        XCTAssertThrowsError(try model.finish(), "finish() must propagate store save failures") { error in
            XCTAssertTrue(error is ThrowingNoteStore.SaveError)
        }
    }

    func testFinishSucceedsWithWorkingStore() throws {
        let working = RecordingNoteStore()
        let model = DictationViewModel(store: working)
        model.injectFinalized("A note that saves fine.")

        let note = try XCTUnwrap(try model.finish())
        XCTAssertEqual(working.saved.count, 1)
        XCTAssertEqual(working.saved.first?.id, note.id)
    }

    // MARK: - Partial-on-stop fold (test hook mirrors injectFinalized)

    func testPartialPresentAtFinishLandsInSavedNote() throws {
        let model = DictationViewModel(store: store)
        model.injectFinalized("First finalized paragraph.")
        // A partial phrase is on screen but was never finalized before the user hit Stop.
        model.simulatePartial("A trailing thought mid sentence")

        let note = try XCTUnwrap(try model.finish())
        XCTAssertEqual(note.paragraphs, [
            "First finalized paragraph.",
            "A trailing thought mid sentence"
        ])
    }

    // MARK: - TextProcessor seam

    func testCustomProcessorIsApplied() throws {
        let model = DictationViewModel(store: store, processor: UppercasingProcessor())
        model.injectFinalized("keep it quiet")
        model.simulatePartial("and this too")

        let note = try XCTUnwrap(try model.finish())
        XCTAssertEqual(note.paragraphs, ["KEEP IT QUIET", "AND THIS TOO"])
    }
}

// MARK: - Test doubles

/// A `NoteStoring` stub whose `save` always throws, to exercise the error path.
private final class ThrowingNoteStore: NoteStoring {
    struct SaveError: Error {}

    func save(_ note: Note) throws -> URL {
        throw SaveError()
    }

    func loadAll() -> [Note] { [] }
    func delete(id: UUID) throws {}
}

/// A `NoteStoring` stub that records saves in memory and never fails. `@unchecked Sendable`: it is
/// only touched from the test's single actor, but `NoteStoring: Sendable` requires the annotation
/// for its mutable buffer.
private final class RecordingNoteStore: NoteStoring, @unchecked Sendable {
    private(set) var saved: [Note] = []

    @discardableResult
    func save(_ note: Note) throws -> URL {
        saved.append(note)
        return URL(fileURLWithPath: "/dev/null")
    }

    func loadAll() -> [Note] { saved }
    func delete(id: UUID) throws {
        saved.removeAll { $0.id == id }
    }
}

/// A processor that uppercases text, to prove the injectable transform seam is applied.
private struct UppercasingProcessor: TextProcessor {
    func process(_ text: String) -> ProcessedSegment { .text(text.uppercased()) }
}
