import XCTest
@testable import ThoughtBuffer

/// `NewThoughtPlacement` (spec 0026): the pure decision for where a new thought is filed. Inside a user
/// folder -> that folder; from the top level / All Thoughts / Recents / a hands-free entry point ->
/// uncategorized (the store root, empty `folderPath`).
final class NewThoughtPlacementTests: XCTestCase {
    // MARK: - Subject-driven mapping (the real view decision)

    func testUserFolderSubjectFilesInThatFolder() {
        XCTAssertEqual(NewThoughtPlacement.folderPath(for: .userFolder("Work")), ["Work"])
    }

    func testAllThoughtsAliasSubjectFilesUncategorized() {
        XCTAssertEqual(NewThoughtPlacement.folderPath(for: .alias(.allThoughts)), [])
    }

    func testRecentsAliasSubjectFilesUncategorized() {
        XCTAssertEqual(NewThoughtPlacement.folderPath(for: .alias(.recents)), [])
    }

    // MARK: - Raw browsing-folder mapping (top level + hands-free)

    func testInsideAUserFolderFilesInThatFolder() {
        XCTAssertEqual(NewThoughtPlacement.folderPath(browsingFolder: ["Work"]), ["Work"])
    }

    func testFromTopLevelFilesUncategorized() {
        // The top level / a hands-free entry point passes `[]` (no user-folder context).
        XCTAssertEqual(NewThoughtPlacement.folderPath(browsingFolder: []), [])
    }

    func testLegacyDeepContextIsPreservedVerbatim() {
        // The documented safety behavior: a deeper context (if ever passed) files at that same location
        // rather than silently re-rooting.
        XCTAssertEqual(NewThoughtPlacement.folderPath(browsingFolder: ["Work", "Q1"]), ["Work", "Q1"])
    }
}
