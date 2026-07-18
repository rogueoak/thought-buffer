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
