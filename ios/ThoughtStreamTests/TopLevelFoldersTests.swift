import XCTest
@testable import ThoughtStream

/// `TopLevelFolders` (spec 0026): the pure projections behind the redesigned folders-only top level. The
/// two virtual aliases (All Thoughts = every thought sorted; Recents = the 10 most recent, newest first), a
/// user folder's flat thoughts (flattened over any legacy nested subtree), and the uncategorized thoughts
/// (store root) are all pure functions over the loaded list, tested here without any UI.
final class TopLevelFoldersTests: XCTestCase {
    private func thought(_ title: String, _ epoch: TimeInterval, folder: [String] = [], id: UUID = UUID()) -> Thought {
        Thought(id: id, title: title, paragraphs: ["b"], createdAt: Date(timeIntervalSince1970: epoch), folderPath: folder)
    }

    private func titles(_ thoughts: [Thought]) -> [String] { thoughts.map(\.title) }

    // MARK: - All Thoughts (every thought, honoring sort)

    func testAllThoughtsIncludesEveryThoughtRegardlessOfFolder() {
        let thoughts = [
            thought("root", 1_000, folder: []),
            thought("work", 2_000, folder: ["Work"]),
            thought("deep", 3_000, folder: ["Work", "Q1"]),
        ]
        let all = TopLevelFolders.allThoughts(thoughts, sorted: .newest)
        XCTAssertEqual(Set(titles(all)), Set(["root", "work", "deep"]))
    }

    func testAllThoughtsHonorsSortOrder() {
        let thoughts = [
            thought("beta", 1_000, folder: []),
            thought("alpha", 3_000, folder: ["Work"]),
            thought("gamma", 2_000, folder: []),
        ]
        XCTAssertEqual(titles(TopLevelFolders.allThoughts(thoughts, sorted: .newest)), ["alpha", "gamma", "beta"])
        XCTAssertEqual(titles(TopLevelFolders.allThoughts(thoughts, sorted: .oldest)), ["beta", "gamma", "alpha"])
        XCTAssertEqual(titles(TopLevelFolders.allThoughts(thoughts, sorted: .titleAZ)), ["alpha", "beta", "gamma"])
        XCTAssertEqual(titles(TopLevelFolders.allThoughts(thoughts, sorted: .titleZA)), ["gamma", "beta", "alpha"])
    }

    // MARK: - Recents (last 10, newest first)

    func testRecentsFewerThanLimitReturnsAllNewestFirst() {
        let thoughts = [
            thought("a", 1_000),
            thought("b", 3_000),
            thought("c", 2_000),
        ]
        XCTAssertEqual(titles(TopLevelFolders.recents(thoughts)), ["b", "c", "a"])
    }

    func testRecentsExactlyTenReturnsAllNewestFirst() {
        let thoughts = (0..<10).map { thought("t\($0)", TimeInterval($0 * 100)) }
        let recents = TopLevelFolders.recents(thoughts)
        XCTAssertEqual(recents.count, 10)
        XCTAssertEqual(titles(recents), (0..<10).reversed().map { "t\($0)" })
    }

    func testRecentsMoreThanTenCapsToTenNewest() {
        let thoughts = (0..<25).map { thought("t\($0)", TimeInterval($0 * 100)) }
        let recents = TopLevelFolders.recents(thoughts)
        XCTAssertEqual(recents.count, 10)
        // The ten newest are t24..t15, newest first.
        XCTAssertEqual(titles(recents), (15..<25).reversed().map { "t\($0)" })
    }

    func testRecentsIsNewestFirstRegardlessOfInputOrder() {
        let thoughts = [
            thought("oldest", 1_000),
            thought("newest", 9_000),
            thought("middle", 5_000),
        ]
        XCTAssertEqual(titles(TopLevelFolders.recents(thoughts, limit: 2)), ["newest", "middle"])
    }

    func testRecentsBreaksCreatedAtTiesDeterministically() {
        let idA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let idB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        // Same createdAt: the stable id tie-break (idA < idB) fixes the order.
        let thoughts = [
            thought("B", 5_000, id: idB),
            thought("A", 5_000, id: idA),
        ]
        let recents = TopLevelFolders.recents(thoughts)
        XCTAssertEqual(recents.map(\.id), [idA, idB])
    }

    func testRecentsEmptyIsEmpty() {
        XCTAssertTrue(TopLevelFolders.recents([]).isEmpty)
    }

    // MARK: - User folder thoughts (flattened over legacy nesting)

    func testFolderThoughtsFlattensLegacyNestedSubtree() {
        let thoughts = [
            thought("direct", 1_000, folder: ["Work"]),
            thought("nested", 2_000, folder: ["Work", "Q1"]),
            thought("deeper", 3_000, folder: ["Work", "Q1", "Jan"]),
            thought("elsewhere", 4_000, folder: ["Other"]),
            thought("uncategorized", 5_000, folder: []),
        ]
        let work = TopLevelFolders.folderThoughts(thoughts, folder: "Work", sorted: .oldest)
        // All three under Work (direct + both nested) surface, flattened, and NOT the others.
        XCTAssertEqual(titles(work), ["direct", "nested", "deeper"])
    }

    func testFolderThoughtsHonorsSort() {
        let thoughts = [
            thought("mango", 1_000, folder: ["Fruit"]),
            thought("apple", 2_000, folder: ["Fruit"]),
        ]
        XCTAssertEqual(titles(TopLevelFolders.folderThoughts(thoughts, folder: "Fruit", sorted: .titleAZ)), ["apple", "mango"])
        XCTAssertEqual(titles(TopLevelFolders.folderThoughts(thoughts, folder: "Fruit", sorted: .newest)), ["apple", "mango"])
    }

    func testFolderThoughtCountCountsFlattenedSubtree() {
        let thoughts = [
            thought("d", 1_000, folder: ["Work"]),
            thought("n", 2_000, folder: ["Work", "Q1"]),
            thought("other", 3_000, folder: ["Other"]),
        ]
        XCTAssertEqual(TopLevelFolders.folderThoughtCount(thoughts, folder: "Work"), 2)
        XCTAssertEqual(TopLevelFolders.folderThoughtCount(thoughts, folder: "Missing"), 0)
    }

    // MARK: - Uncategorized (store root)

    func testUncategorizedIsOnlyRootThoughtsAndExcludesFoldered() {
        let thoughts = [
            thought("root a", 1_000, folder: []),
            thought("root b", 2_000, folder: []),
            thought("in folder", 3_000, folder: ["Work"]),
            thought("nested", 4_000, folder: ["Work", "Q1"]),
        ]
        let uncategorized = TopLevelFolders.uncategorized(thoughts, sorted: .newest)
        XCTAssertEqual(titles(uncategorized), ["root b", "root a"])
    }

    // MARK: - User folder names

    func testUserFolderNamesAreCaseInsensitiveAZ() {
        XCTAssertEqual(
            TopLevelFolders.userFolderNames(childFolderNames: ["zeta", "Alpha", "beta"]),
            ["Alpha", "beta", "zeta"]
        )
    }

    // MARK: - Count label pluralization

    func testThoughtCountLabelBoundaries() {
        XCTAssertEqual(TopLevelFolders.thoughtCountLabel(0), "No thoughts")
        XCTAssertEqual(TopLevelFolders.thoughtCountLabel(1), "1 thought")
        XCTAssertEqual(TopLevelFolders.thoughtCountLabel(2), "2 thoughts")
    }

    // MARK: - Aliases are fixed, virtual

    func testAliasFoldersHaveStableTitles() {
        XCTAssertEqual(AliasFolder.allThoughts.title, "All Thoughts")
        XCTAssertEqual(AliasFolder.recents.title, "Recents")
        // Exactly the two aliases exist, in the pinned order.
        XCTAssertEqual(AliasFolder.allCases, [.allThoughts, .recents])
    }
}
