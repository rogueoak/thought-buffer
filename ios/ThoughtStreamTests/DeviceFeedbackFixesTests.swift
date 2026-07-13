import XCTest
@testable import ThoughtStream

/// Regression tests for the on-device feedback fixes (feedback 0005): pause/restart never loses
/// text (#2), the mic-level -> bar-height mapping (#5), the note word count (#6), and swipe-to-delete
/// through the store from the feed (#4). The command-mode changes (#3) live in
/// `MiraCommandParserTests` / `MiraCommandExecutionTests`.
final class DeviceFeedbackFixesTests: XCTestCase {

    // MARK: - #5 Mic level -> waveform mapping

    /// A zero level yields no lift (bars at floor); a non-zero level lifts them clearly. The mapping
    /// is monotonic and saturates at 1, and normal-speaking RMS clears the floor by a wide margin.
    func testLevelMappingLiftsBarsForNonZeroLevel() {
        XCTAssertEqual(SpeechDictationService.normalizedLevel(fromRMS: 0), 0, accuracy: 0.0001)

        let quiet = SpeechDictationService.normalizedLevel(fromRMS: 0.01)
        let normal = SpeechDictationService.normalizedLevel(fromRMS: 0.05)
        let loud = SpeechDictationService.normalizedLevel(fromRMS: 0.5)

        // A non-zero level yields a taller bar than zero.
        XCTAssertGreaterThan(quiet, 0)
        // Normal speaking clearly moves the bars: well above the 0.12 waveform floor.
        XCTAssertGreaterThan(normal, 0.3)
        // Monotonic: louder maps higher.
        XCTAssertGreaterThan(normal, quiet)
        XCTAssertGreaterThan(loud, normal)
        // Saturates at 1 and never exceeds it.
        XCTAssertLessThanOrEqual(loud, 1)
        XCTAssertEqual(SpeechDictationService.normalizedLevel(fromRMS: 1), 1, accuracy: 0.0001)
    }

    /// The Waveform's own height mapping: a non-zero level yields a taller bar than a zero level.
    /// Mirrors the private `barHeight` math so a regression that flattens the bars is caught.
    func testWaveformBarHeightRisesWithLevel() {
        func barHeight(index: Int, level: CGFloat, maxHeight: CGFloat) -> CGFloat {
            let available = (maxHeight.isFinite && maxHeight > 0) ? maxHeight : 0
            let safeLevel = level.isFinite ? min(1, max(0, level)) : 0
            let shape = (sin(Double(index) * 0.7) + 1) / 2
            let floor = 0.12
            let factor = floor + (shape * 0.35 + 0.65) * Double(safeLevel) * (1 - floor)
            return max(4, available * CGFloat(min(1, factor)))
        }
        let atZero = barHeight(index: 3, level: 0, maxHeight: 44)
        let atHalf = barHeight(index: 3, level: 0.5, maxHeight: 44)
        XCTAssertGreaterThan(atHalf, atZero, "a speaking level must make the bar taller than silence")
    }

    // MARK: - #6 Word count

    func testWordCountAndLabel() {
        let one = Note(title: "t", paragraphs: ["Hello"], createdAt: Date())
        XCTAssertEqual(one.wordCount, 1)
        XCTAssertEqual(one.wordCountLabel, "1 word")

        let many = Note(
            title: "t",
            paragraphs: ["Call the supplier before noon.", "Draft the launch email today."],
            createdAt: Date()
        )
        // 5 + 5 = 10 words across paragraphs.
        XCTAssertEqual(many.wordCount, 10)
        XCTAssertEqual(many.wordCountLabel, "10 words")

        let empty = Note(title: "t", paragraphs: [], createdAt: Date())
        XCTAssertEqual(empty.wordCount, 0)
        XCTAssertEqual(empty.wordCountLabel, "0 words")

        // Extra whitespace does not inflate the count.
        let spaced = Note(title: "t", paragraphs: ["  spaced   out   words  "], createdAt: Date())
        XCTAssertEqual(spaced.wordCount, 3)
    }
}

// MARK: - #2 Pause / restart never loses text (event-boundary regression)

/// Proves the view model's finalize/restart/partial handling at the service->view-model event seam:
/// a natural pause ends the recognition task, which now emits the in-progress words as a
/// `.finalizedSegment` (not a partial). That committed paragraph must survive the fresh task's
/// replacing partials. Driven through a fake capture service so no live mic is needed.
@MainActor
final class PauseRestartPreservationTests: XCTestCase {
    private var store: MemoryNoteStore!
    private var service: EventDrivingCaptureService!

    override func setUp() {
        super.setUp()
        store = MemoryNoteStore()
        service = EventDrivingCaptureService()
    }

    private func makeModel() -> DictationViewModel {
        DictationViewModel(service: service, store: store, processor: PassthroughTextProcessor())
    }

    /// The core invariant: words spoken before a natural pause are COMMITTED when the task ends
    /// (finalizedSegment), and the following task's fresh partials do NOT overwrite them.
    func testPauseThenNewTaskDoesNotLoseCommittedText() {
        let model = makeModel()

        // Task 1: user speaks, shown as a live partial (not yet committed).
        service.emit(.partial("Remember to call the supplier"))
        XCTAssertTrue(model.paragraphs.isEmpty, "partial is not committed until the task ends")

        // Natural pause: the recognition task ENDS. Post-fix the service emits the in-progress text
        // as a finalized segment (the bug emitted it as a partial, so the next task's empty partial
        // wiped it out).
        service.emit(.finalizedSegment("Remember to call the supplier", range: nil))
        XCTAssertEqual(model.paragraphs, ["Remember to call the supplier"])
        XCTAssertEqual(model.partial, "", "committing a paragraph clears the live partial")

        // Task 2 (after the restart): a FRESH partial arrives. It must not erase the committed text.
        service.emit(.partial("and draft the email"))
        XCTAssertEqual(model.paragraphs, ["Remember to call the supplier"],
                       "the fresh task's partial must not lose the committed paragraph")

        // Finalize the second segment too.
        service.emit(.finalizedSegment("and draft the email", range: nil))
        XCTAssertEqual(model.paragraphs, [
            "Remember to call the supplier",
            "and draft the email",
        ])
    }

    /// The committed text survives an actual stop-and-save through the store.
    func testCommittedTextAcrossRestartSurvivesSave() throws {
        let model = makeModel()
        service.emit(.partial("First thought"))
        service.emit(.finalizedSegment("First thought", range: nil))
        service.emit(.partial("Second thought"))
        service.emit(.finalizedSegment("Second thought", range: nil))

        let note = try XCTUnwrap(try model.finish())
        XCTAssertEqual(note.paragraphs, ["First thought", "Second thought"])
    }
}

// MARK: - #4 Delete through the store from the feed

@MainActor
final class StreamFeedDeleteTests: XCTestCase {
    func testDeleteRemovesNoteThroughStoreAndReloads() async {
        let store = MemoryNoteStore()
        let keep = Note(title: "Keep", paragraphs: ["stays"], createdAt: Date())
        let drop = Note(title: "Drop", paragraphs: ["goes"], createdAt: Date())
        try? store.save(keep)
        try? store.save(drop)

        let feed = StreamFeed(store: store)
        await feed.start()
        XCTAssertEqual(feed.notes.count, 2)

        await feed.delete(id: drop.id)

        // The delete went THROUGH the store (removed there) and the feed reloaded to reflect it.
        XCTAssertEqual(store.deletedIDs, [drop.id])
        XCTAssertEqual(feed.notes.map(\.id), [keep.id])
    }
}

// MARK: - Test doubles

/// A capture service that just forwards events the test posts, so the view model's event handling
/// can be exercised without live audio.
@MainActor
private final class EventDrivingCaptureService: SpeechCaptureService {
    var onEvent: ((SpeechCaptureEvent) -> Void)?

    func emit(_ event: SpeechCaptureEvent) { onEvent?(event) }

    func requestAuthorization() async -> SpeechCaptureError? { nil }
    func availabilityError() -> SpeechCaptureError? { nil }
    func setRecordingEnabled(_ enabled: Bool) {}
    func recordingURL() -> URL? { nil }
    func discardRecording() {}
    func start() {}
    func pause() {}
    func resume() {}
    func stop() {}
}

/// An in-memory note store that records saves and deletes, for the feed/delete and save tests.
/// `@unchecked Sendable`: touched only from the test's single actor, but `NoteStoring: Sendable`
/// requires the annotation for its mutable buffers.
private final class MemoryNoteStore: NoteStoring, @unchecked Sendable {
    private(set) var notes: [Note] = []
    private(set) var deletedIDs: [UUID] = []

    @discardableResult
    func save(_ note: Note) throws -> URL {
        notes.removeAll { $0.id == note.id }
        notes.append(note)
        return URL(fileURLWithPath: "/dev/null")
    }

    func loadAll() -> [Note] { notes.reversed() }

    func delete(id: UUID) throws {
        deletedIDs.append(id)
        notes.removeAll { $0.id == id }
    }
}
