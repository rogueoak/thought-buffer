import XCTest
@testable import ThoughtBuffer

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
        // SAME createdAt AND SAME title, so only the id tie-break can decide the order (idA < idB). Using
        // distinct titles would let the title tie-break decide first and never exercise the id fallback.
        let thoughts = [
            thought("same", 5_000, id: idB),
            thought("same", 5_000, id: idA),
        ]
        let recents = TopLevelFolders.recents(thoughts)
        XCTAssertEqual(recents.map(\.id), [idA, idB])
    }

    func testRecentsLimitZeroReturnsNone() {
        let thoughts = [thought("a", 1_000), thought("b", 2_000)]
        XCTAssertTrue(TopLevelFolders.recents(thoughts, limit: 0).isEmpty)
    }

    func testRecentsNegativeLimitReturnsAllNewestFirst() {
        let thoughts = [thought("a", 1_000), thought("c", 3_000), thought("b", 2_000)]
        XCTAssertEqual(titles(TopLevelFolders.recents(thoughts, limit: -1)), ["c", "b", "a"])
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
        // Diverging data so .titleAZ and .newest produce DIFFERENT orders (title order != date order): "apple"
        // is newer than "mango", so titleAZ = [apple, mango] but newest = [apple, mango] would coincide -
        // flip the dates so newest is [mango, apple] while titleAZ stays [apple, mango].
        let thoughts = [
            thought("mango", 2_000, folder: ["Fruit"]),
            thought("apple", 1_000, folder: ["Fruit"]),
        ]
        XCTAssertEqual(titles(TopLevelFolders.folderThoughts(thoughts, folder: "Fruit", sorted: .titleAZ)), ["apple", "mango"])
        XCTAssertEqual(titles(TopLevelFolders.folderThoughts(thoughts, folder: "Fruit", sorted: .newest)), ["mango", "apple"])
        XCTAssertEqual(titles(TopLevelFolders.folderThoughts(thoughts, folder: "Fruit", sorted: .oldest)), ["apple", "mango"])
    }

    func testFolderMembershipIsComponentEqualityNotStringPrefix() {
        // "Work" must NOT swallow "Workshop": membership is folderPath.first EQUALITY, not a string prefix.
        let thoughts = [
            thought("in work", 1_000, folder: ["Work"]),
            thought("in workshop", 2_000, folder: ["Workshop"]),
        ]
        XCTAssertEqual(titles(TopLevelFolders.folderThoughts(thoughts, folder: "Work", sorted: .newest)), ["in work"])
        XCTAssertEqual(TopLevelFolders.folderThoughtCount(thoughts, folder: "Work"), 1)
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

    func testFolderThoughtCountsBucketsEveryFolderInOnePass() {
        let thoughts = [
            thought("a", 1_000, folder: ["Work"]),
            thought("b", 2_000, folder: ["Work", "Q1"]),
            thought("c", 3_000, folder: ["Other"]),
            thought("d", 4_000, folder: []), // uncategorized: contributes to no folder
        ]
        let counts = TopLevelFolders.folderThoughtCounts(thoughts)
        XCTAssertEqual(counts["Work"], 2)
        XCTAssertEqual(counts["Other"], 1)
        // An uncategorized thought and an unknown folder are absent from the map.
        XCTAssertNil(counts["Missing"])
        XCTAssertEqual(counts.count, 2)
    }

    /// Drift guard: `folderThoughtCounts` (the one-pass bucket used by the top-level list) and
    /// `folderThoughts(...).count` are TWO implementations of the same `belongs` membership rule. Pin that
    /// they agree for EVERY folder in a mixed fixture, so a future edit to either path fails CI.
    func testFolderThoughtCountsAgreesWithFolderThoughtsCount() {
        let thoughts = [
            thought("a", 1_000, folder: ["Work"]),
            thought("b", 2_000, folder: ["Work", "Q1"]),      // legacy-nested under Work
            thought("c", 3_000, folder: ["Work", "Q1", "Jan"]), // deeper legacy nesting under Work
            thought("d", 4_000, folder: ["Workshop"]),          // prefix-collision sibling, NOT Work
            thought("e", 5_000, folder: ["Other"]),
            thought("f", 6_000, folder: []),                    // uncategorized
        ]
        let counts = TopLevelFolders.folderThoughtCounts(thoughts)
        // Every folder that appears as a first component must agree across both paths.
        for name in ["Work", "Workshop", "Other", "Missing"] {
            let viaList = TopLevelFolders.folderThoughts(thoughts, folder: name, sorted: .newest).count
            let viaCount = TopLevelFolders.folderThoughtCount(thoughts, folder: name)
            let viaBucket = counts[name] ?? 0
            XCTAssertEqual(viaList, viaCount, "list vs count disagree for \(name)")
            XCTAssertEqual(viaCount, viaBucket, "count vs bucket disagree for \(name)")
        }
        // Concrete values pinning the flatten: Work has 3 (direct + two legacy-nested), Workshop 1, Other 1.
        XCTAssertEqual(counts["Work"], 3)
        XCTAssertEqual(counts["Workshop"], 1)
        XCTAssertEqual(counts["Other"], 1)
    }

    // MARK: - Uncategorized (store root)

    func testUncategorizedIsOnlyRootThoughtsAndExcludesFoldered() {
        let thoughts = [
            thought("root a", 1_000, folder: []),
            thought("root b", 2_000, folder: []),
            thought("in folder", 3_000, folder: ["Work"]),
            thought("nested", 4_000, folder: ["Work", "Q1"]),
        ]
        // Newest-first excludes every foldered thought.
        XCTAssertEqual(titles(TopLevelFolders.uncategorized(thoughts, sorted: .newest)), ["root b", "root a"])
        // Honors another sort order too (not hard-wired to newest).
        XCTAssertEqual(titles(TopLevelFolders.uncategorized(thoughts, sorted: .oldest)), ["root a", "root b"])
    }

    func testUncategorizedIsEmptyWhenEveryThoughtIsFoldered() {
        let thoughts = [
            thought("in folder", 1_000, folder: ["Work"]),
            thought("nested", 2_000, folder: ["Work", "Q1"]),
        ]
        XCTAssertTrue(TopLevelFolders.uncategorized(thoughts, sorted: .newest).isEmpty)
    }

    // MARK: - Subject-driven projection

    func testThoughtsForSubjectRoutesEachCase() {
        let thoughts = [
            thought("root new", 5_000, folder: []),
            thought("root old", 1_000, folder: []),
            thought("work", 3_000, folder: ["Work"]),
        ]
        // A user folder -> its flattened thoughts.
        XCTAssertEqual(titles(TopLevelFolders.thoughts(thoughts, for: .userFolder("Work"), sorted: .newest)), ["work"])
        // All Thoughts -> every thought, sorted.
        XCTAssertEqual(
            Set(titles(TopLevelFolders.thoughts(thoughts, for: .alias(.allThoughts), sorted: .newest))),
            Set(["root new", "root old", "work"])
        )
        // Recents -> newest first, ignoring the chosen sort order (pass .oldest, still newest-first).
        XCTAssertEqual(
            titles(TopLevelFolders.thoughts(thoughts, for: .alias(.recents), sorted: .oldest)),
            ["root new", "work", "root old"]
        )
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
