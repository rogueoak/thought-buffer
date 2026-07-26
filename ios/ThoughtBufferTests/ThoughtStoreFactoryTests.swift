import XCTest
@testable import ThoughtBuffer

/// Storage selection and fallback: the factory picks iCloud when the ubiquity container resolves
/// and the local store when it does not, using an injected provider boundary so the choice is
/// provable with no real iCloud account.
final class ThoughtStoreFactoryTests: XCTestCase {
    /// A container provider double that resolves a fixed URL (or nil) so tests drive the
    /// iCloud-present vs iCloud-absent paths without touching FileManager's ubiquity lookup.
    private struct StubContainerProvider: UbiquityContainerProviding {
        let containerIdentifier: String?
        let url: URL?
        init(url: URL?) {
            self.containerIdentifier = "iCloud.test"
            self.url = url
        }
        func containerURL() async -> URL? { url }
    }

    /// A no-op observer so selecting iCloud does not spin up a real NSMetadataQuery in tests.
    private final class StubObserver: UbiquitousThoughtObserving {
        var onChange: (() -> Void)?
        private(set) var started = false
        func start() { started = true }
        func stop() { started = false }
    }

    func testSelectsICloudWhenContainerResolves() async {
        let containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-\(UUID().uuidString)", isDirectory: true)
        let factory = ThoughtStoreFactory(
            containerProvider: StubContainerProvider(url: containerURL),
            makeObserver: { StubObserver() }
        )

        let selection = await factory.make()

        XCTAssertEqual(selection.kind, .iCloud)
        XCTAssertTrue(selection.store is ICloudThoughtStore)
        XCTAssertNotNil(selection.observer, "iCloud selection should provide a live-update observer")
        // The store roots under the container's Documents/ThoughtBuffer.
        let store = selection.store as! ICloudThoughtStore
        XCTAssertEqual(store.directory.lastPathComponent, "ThoughtBuffer")
        XCTAssertTrue(store.directory.path.contains("Documents"))
    }

    func testFallsBackToLocalWhenContainerAbsent() async {
        let factory = ThoughtStoreFactory(
            containerProvider: StubContainerProvider(url: nil),
            makeObserver: { StubObserver() }
        )

        let selection = await factory.make()

        XCTAssertEqual(selection.kind, .local)
        XCTAssertTrue(selection.store is ThoughtStore)
        XCTAssertNil(selection.observer, "local selection has nothing external to observe")
    }

    /// Fallback correctness: when iCloud is absent, the selected store behaves like the local
    /// store - a save/load round-trip works exactly as before.
    func testFallbackStoreRoundTripsLikeLocal() async throws {
        let factory = ThoughtStoreFactory(
            containerProvider: StubContainerProvider(url: nil),
            makeObserver: { StubObserver() }
        )
        let selection = await factory.make()

        // Exercise the RETURNED store, not a fresh one, so the round-trip proves what the factory
        // actually hands back. It roots at the real Documents dir, so use a uniquely-identified thought
        // and delete it afterwards to leave no residue.
        let store = try XCTUnwrap(selection.store as? ThoughtStore)
        let thought = Thought(title: "local", paragraphs: ["Still works offline."], createdAt: Date())
        try store.save(thought)
        defer { try? store.delete(id: thought.id) }

        let loaded = try XCTUnwrap(store.load(id: thought.id))
        XCTAssertEqual(loaded.title, "local")
    }

    /// AppDependencies.resolve threads the factory's choice through the composition root, so the
    /// app holds the kind for a future Settings status.
    func testAppDependenciesResolveCarriesKind() async {
        let factory = ThoughtStoreFactory(
            containerProvider: StubContainerProvider(url: nil),
            makeObserver: { StubObserver() }
        )
        let deps = await AppDependencies.resolve(factory: factory)
        XCTAssertEqual(deps.thoughtStoreKind, .local)
        XCTAssertNil(deps.thoughtObserver)
    }
}
