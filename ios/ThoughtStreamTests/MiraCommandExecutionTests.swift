import XCTest
@testable import ThoughtStream

/// Command execution in the view model: note mutations, new note (save + reset), read-back
/// (Speaker + capture pause/resume), and TextProcessor result routing (command consumed vs text
/// committed). Driven without live audio by injecting finalized segments.
@MainActor
final class MiraCommandExecutionTests: XCTestCase {
    private var store: RecordingNoteStore!

    override func setUp() {
        super.setUp()
        store = RecordingNoteStore()
    }

    private func makeModel(
        service: SpeechCaptureService? = nil,
        speaker: Speaker? = nil
    ) -> DictationViewModel {
        DictationViewModel(
            service: service ?? StubCaptureService(),
            store: store,
            processor: MiraTextProcessor(),
            speaker: speaker ?? StubSpeaker()
        )
    }

    // MARK: - TextProcessor routing

    func testCommandSegmentIsConsumedNotCommitted() {
        let model = makeModel()
        model.injectFinalized("First paragraph.")
        model.injectFinalized("Mira remove the last paragraph")
        // The command phrase never lands in the note, and it removed the one paragraph.
        XCTAssertEqual(model.paragraphs, [])
    }

    func testOrdinaryTextIsCommitted() {
        let model = makeModel()
        model.injectFinalized("A perfectly ordinary sentence.")
        XCTAssertEqual(model.paragraphs, ["A perfectly ordinary sentence."])
    }

    // MARK: - Remove last sentence

    func testRemoveLastSentence() {
        let model = makeModel()
        model.injectFinalized("Call the supplier. Draft the email.")
        model.injectFinalized("Mira remove the last sentence")
        XCTAssertEqual(model.paragraphs, ["Call the supplier."])
    }

    func testRemoveLastSentenceEmptiesParagraphAndDropsIt() {
        let model = makeModel()
        model.injectFinalized("A single thought.")
        model.injectFinalized("Mira remove the last sentence")
        XCTAssertEqual(model.paragraphs, [])
    }

    func testRemoveLastSentenceOnEmptyNoteIsNoOp() {
        let model = makeModel()
        model.injectFinalized("Mira remove the last sentence")
        XCTAssertEqual(model.paragraphs, [])
    }

    // MARK: - Remove last paragraph

    func testRemoveLastParagraph() {
        let model = makeModel()
        model.injectFinalized("First.")
        model.injectFinalized("Second.")
        model.injectFinalized("Mira remove the last paragraph")
        XCTAssertEqual(model.paragraphs, ["First."])
    }

    func testRemoveLastParagraphOnEmptyNoteIsNoOp() {
        let model = makeModel()
        model.injectFinalized("Mira remove the last paragraph")
        XCTAssertEqual(model.paragraphs, [])
    }

    // MARK: - New note

    func testNewNoteSavesCurrentAndResets() {
        let model = makeModel()
        model.injectFinalized("A note worth keeping.")
        model.injectFinalized("Mira new note")

        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(store.saved.first?.paragraphs, ["A note worth keeping."])
        XCTAssertEqual(model.paragraphs, [], "the note should reset after new note")

        // The fresh note is independent: a second save writes a new file with a new id.
        model.injectFinalized("A second, separate note.")
        model.injectFinalized("Mira new note")
        XCTAssertEqual(store.saved.count, 2)
        XCTAssertNotEqual(store.saved[0].id, store.saved[1].id)
    }

    func testNewNoteWithEmptyNoteSavesNothing() {
        let model = makeModel()
        model.injectFinalized("Mira new note")
        XCTAssertEqual(store.saved.count, 0)
        XCTAssertEqual(model.paragraphs, [])
    }

    // MARK: - Read that back

    func testReadThatBackSpeaksLastParagraphAndCyclesCapture() async {
        let speaker = StubSpeaker()
        let service = StubCaptureService()
        let model = makeModel(service: service, speaker: speaker)

        // Bring the model to the recording phase so read-back pauses/resumes capture.
        await model.begin()
        XCTAssertTrue(model.isRecording)

        model.injectFinalized("First paragraph.")
        model.injectFinalized("The paragraph to read back.")
        model.injectFinalized("Mira read that back")

        XCTAssertEqual(speaker.spoken, ["The paragraph to read back."])
        // Capture paused for playback; nothing was committed for the command phrase.
        XCTAssertEqual(service.pauseCount, 1)
        XCTAssertEqual(service.resumeCount, 0)
        XCTAssertEqual(model.paragraphs, ["First paragraph.", "The paragraph to read back."])

        // When the utterance finishes, capture resumes.
        speaker.finish()
        XCTAssertEqual(service.resumeCount, 1)
    }

    func testReadThatBackOnEmptyNoteDoesNotSpeak() {
        let speaker = StubSpeaker()
        let model = makeModel(speaker: speaker)
        model.injectFinalized("Mira read that back")
        XCTAssertTrue(speaker.spoken.isEmpty)
    }

    // MARK: - Banner

    func testCommandFiresBanner() {
        let model = makeModel()
        model.injectFinalized("First.")
        model.injectFinalized("Mira remove the last paragraph")
        XCTAssertEqual(model.commandBanner, .removedLastParagraph)
    }
}

// MARK: - Test doubles

/// A `NoteStoring` stub that records saves in memory and never fails.
private final class RecordingNoteStore: NoteStoring {
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

/// A `Speaker` stub that records what was spoken and lets the test drive the finish callback.
@MainActor
private final class StubSpeaker: Speaker {
    var onFinish: (() -> Void)?
    private(set) var spoken: [String] = []

    func speak(_ text: String) {
        spoken.append(text)
    }

    func stop() {}

    /// Simulate the utterance finishing, as the production speaker's delegate would.
    func finish() {
        onFinish?()
    }
}

/// A `SpeechCaptureService` stub that counts lifecycle calls, so read-back's pause/resume can be
/// asserted without touching real audio.
@MainActor
private final class StubCaptureService: SpeechCaptureService {
    var onEvent: ((SpeechCaptureEvent) -> Void)?
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0

    func requestAuthorization() async -> SpeechCaptureError? { nil }
    func availabilityError() -> SpeechCaptureError? { nil }
    func start() {}
    func pause() { pauseCount += 1 }
    func resume() { resumeCount += 1 }
    func stop() {}
}
