import XCTest
@testable import ThoughtStream

/// The Stream feed's load and iCloud-observer wiring - the load-bearing glue that keeps the list
/// in sync with storage. Exercised with an in-memory store and a stub observer, so start/stop,
/// the onChange->reload rewire, and the local (no-observer) path are all provable without SwiftUI
/// or real iCloud.
@MainActor
final class StreamFeedTests: XCTestCase {
    /// An in-memory NoteStoring whose loadAll returns whatever it was told to, so a change can be
    /// simulated between reloads.
    private final class InMemoryStore: NoteStoring, @unchecked Sendable {
        var notes: [Note] = []
        private(set) var loadCount = 0
        func save(_ note: Note) throws -> URL { URL(fileURLWithPath: "/dev/null") }
        func loadAll() -> [Note] { loadCount += 1; return notes }
        func delete(id: UUID) throws {}
    }

    /// A stub iCloud observer that records start/stop and lets a test fire onChange by hand.
    private final class StubObserver: UbiquitousNoteObserving {
        var onChange: (() -> Void)?
        private(set) var startCount = 0
        private(set) var stopCount = 0
        func start() { startCount += 1 }
        func stop() { stopCount += 1 }
        /// Simulate a metadata change synced in from another device.
        func fireChange() { onChange?() }
    }

    func testStartLoadsNotes() async {
        let store = InMemoryStore()
        store.notes = [Note(title: "a", paragraphs: ["A."], createdAt: Date())]
        let feed = StreamFeed(store: store)

        XCTAssertFalse(feed.didLoad)
        await feed.start()

        XCTAssertTrue(feed.didLoad)
        XCTAssertEqual(feed.notes.map(\.title), ["a"])
        XCTAssertEqual(store.loadCount, 1)
    }

    func testStartWithoutObserverDoesNotObserve() async {
        // Local storage: no observer to start. Should still load and never crash.
        let store = InMemoryStore()
        let feed = StreamFeed(store: store, observer: nil)
        await feed.start()
        XCTAssertTrue(feed.didLoad)
        feed.stop() // no-op, must not crash
    }

    func testStartWiresAndStartsObserver() async {
        let store = InMemoryStore()
        let observer = StubObserver()
        let feed = StreamFeed(store: store, observer: observer)

        await feed.start()

        XCTAssertEqual(observer.startCount, 1)
        XCTAssertNotNil(observer.onChange, "start should wire the change closure")
    }

    func testObserverChangeReloadsList() async {
        let store = InMemoryStore()
        store.notes = [Note(title: "first", paragraphs: ["1."], createdAt: Date())]
        let observer = StubObserver()
        let feed = StreamFeed(store: store, observer: observer)
        await feed.start()
        XCTAssertEqual(feed.notes.map(\.title), ["first"])

        // A note syncs in from another device; the metadata query fires.
        store.notes = [
            Note(title: "first", paragraphs: ["1."], createdAt: Date(timeIntervalSince1970: 1)),
            Note(title: "synced", paragraphs: ["2."], createdAt: Date(timeIntervalSince1970: 2)),
        ]
        observer.fireChange()

        // onChange schedules an async reload; yield until it lands.
        await eventually { feed.notes.count == 2 }
        XCTAssertEqual(Set(feed.notes.map(\.title)), ["first", "synced"])
    }

    func testStopTearsDownObserverAndClearsClosure() async {
        let store = InMemoryStore()
        let observer = StubObserver()
        let feed = StreamFeed(store: store, observer: observer)
        await feed.start()

        feed.stop()

        XCTAssertEqual(observer.stopCount, 1)
        XCTAssertNil(observer.onChange, "stop should drop the closure so a lifetime observer holds no stale reference")
    }

    func testStartIsIdempotent() async {
        let store = InMemoryStore()
        let observer = StubObserver()
        let feed = StreamFeed(store: store, observer: observer)

        await feed.start()
        await feed.start()

        // Reloads twice (once per start), but the observer is only started once.
        XCTAssertEqual(observer.startCount, 1)
    }

    /// Poll a condition on the main actor a few times, letting scheduled Tasks run in between.
    private func eventually(_ condition: () -> Bool, tries: Int = 50) async {
        for _ in 0..<tries {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}
