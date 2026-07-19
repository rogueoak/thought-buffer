import XCTest
@testable import ThoughtStream

/// The CarPlay recordings-browser model (spec 0008): projects the shared `ThoughtStoreDriver` to only
/// thoughts that have a recording, newest first, with a formatted duration, and refreshes when the
/// driver's list changes. Proven with an in-memory store + stub observer, so the filter, order,
/// duration formatting, and the driver-change -> list-refresh mapping are all provable without
/// SwiftUI, CarPlay, or real iCloud.
@MainActor
final class RecordingsListModelTests: XCTestCase {

    private final class InMemoryStore: ThoughtStoring, @unchecked Sendable {
        var thoughts: [Thought] = []
        func save(_ thought: Thought) throws -> URL { URL(fileURLWithPath: "/dev/null") }
        func loadAll() -> [Thought] { thoughts }
        func delete(id: UUID) throws {}
    }

    private final class StubObserver: UbiquitousThoughtObserving {
        var onChange: (() -> Void)?
        private(set) var startCount = 0
        private(set) var stopCount = 0
        func start() { startCount += 1 }
        func stop() { stopCount += 1 }
        func fireChange() { onChange?() }
    }

    private func recorded(title: String, at t: TimeInterval, length: Double) -> Thought {
        Thought(
            title: title,
            paragraphs: ["p"],
            createdAt: Date(timeIntervalSince1970: t),
            audioFileName: "\(title).m4a",
            timings: [ParagraphTiming(start: 0, duration: length)]
        )
    }

    private func textOnly(title: String, at t: TimeInterval) -> Thought {
        Thought(title: title, paragraphs: ["p"], createdAt: Date(timeIntervalSince1970: t))
    }

    // MARK: - Filter + order

    func testListsOnlyThoughtsWithAudioNewestFirst() async {
        let store = InMemoryStore()
        // The driver returns newest first; emulate that ordering here.
        store.thoughts = [
            recorded(title: "third", at: 300, length: 10),
            textOnly(title: "no-audio", at: 250),
            recorded(title: "first", at: 100, length: 20),
        ]
        let model = RecordingsListModel(store: store)
        await model.start()

        XCTAssertTrue(model.didLoad)
        XCTAssertEqual(model.entries.map(\.title), ["third", "first"],
                       "only thoughts with audio, in the driver's newest-first order")
    }

    func testEmptyWhenNoThoughtHasAudio() async {
        let store = InMemoryStore()
        store.thoughts = [textOnly(title: "a", at: 1), textOnly(title: "b", at: 2)]
        let model = RecordingsListModel(store: store)
        await model.start()
        XCTAssertTrue(model.didLoad)
        XCTAssertTrue(model.entries.isEmpty)
    }

    // MARK: - Duration formatting (pure)

    func testDurationLabelFormatting() {
        XCTAssertEqual(RecordingsListModel.durationLabel(0), "0:00")
        XCTAssertEqual(RecordingsListModel.durationLabel(-5), "0:00", "negative clamps to 0:00")
        XCTAssertEqual(RecordingsListModel.durationLabel(.nan), "0:00", "NaN clamps to 0:00")
        XCTAssertEqual(RecordingsListModel.durationLabel(5), "0:05")
        XCTAssertEqual(RecordingsListModel.durationLabel(83), "1:23")
        XCTAssertEqual(RecordingsListModel.durationLabel(600), "10:00")
        XCTAssertEqual(RecordingsListModel.durationLabel(3661), "1:01:01", "past an hour shows h:mm:ss")
    }

    func testEntryDetailIncludesTheDuration() async {
        let store = InMemoryStore()
        store.thoughts = [recorded(title: "drive", at: 100, length: 83)]
        let model = RecordingsListModel(store: store)
        await model.start()

        let detail = model.entries.first?.detail ?? ""
        XCTAssertTrue(detail.contains("1:23"), "the detail line carries the recording duration")
    }

    func testRecordingDurationIsTailOfLastParagraph() {
        let thought = Thought(
            title: "t", paragraphs: ["a", "b"], createdAt: Date(),
            audioFileName: "t.m4a",
            timings: [ParagraphTiming(start: 0, duration: 4), ParagraphTiming(start: 4, duration: 6)]
        )
        XCTAssertEqual(thought.recordingDuration, 10, "start + duration of the last-ending range")
    }

    func testRecordingDurationIsOrderIndependent() {
        // `recordingDuration` uses max(start + duration), not `timings.last`, so a timing list that is
        // out of chronological order still yields the true recording length (the tail of the
        // last-ENDING range), never a shorter earlier range.
        let thought = Thought(
            title: "t", paragraphs: ["a", "b"], createdAt: Date(),
            audioFileName: "t.m4a",
            timings: [ParagraphTiming(start: 8, duration: 4), ParagraphTiming(start: 0, duration: 3)]
        )
        XCTAssertEqual(thought.recordingDuration, 12, "the longest tail wins regardless of order")
    }

    // MARK: - Live refresh on driver change

    func testDriverChangeRefreshesTheList() async {
        let store = InMemoryStore()
        store.thoughts = [recorded(title: "first", at: 100, length: 10)]
        let observer = StubObserver()
        let model = RecordingsListModel(store: store, observer: observer)

        var changeCount = 0
        model.onChange = { changeCount += 1 }
        await model.start()
        XCTAssertEqual(model.entries.map(\.title), ["first"])
        let afterStart = changeCount

        // A thought syncs in from another device with a recording; the observer fires.
        store.thoughts = [
            recorded(title: "synced", at: 200, length: 5),
            recorded(title: "first", at: 100, length: 10),
        ]
        observer.fireChange()

        await eventually { model.entries.count == 2 }
        XCTAssertEqual(model.entries.map(\.title), ["synced", "first"])
        XCTAssertGreaterThan(changeCount, afterStart, "a driver change republishes to onChange")
    }

    func testStopTearsDownObserver() async {
        let store = InMemoryStore()
        let observer = StubObserver()
        let model = RecordingsListModel(store: store, observer: observer)
        await model.start()
        model.stop()
        XCTAssertEqual(observer.stopCount, 1)
        XCTAssertNil(observer.onChange)
    }

    private func eventually(_ condition: () -> Bool, tries: Int = 50) async {
        for _ in 0..<tries {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}
