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

        let note = try XCTUnwrap(model.finish(), "expected a saved note")
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

    func testFinishWithNothingCapturedSavesNothing() {
        let model = DictationViewModel(store: store)
        XCTAssertNil(model.finish())
        XCTAssertEqual(store.loadAll().count, 0)
    }
}
