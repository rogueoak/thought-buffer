import XCTest
@testable import ThoughtStream

/// `NewThoughtPlacement` (spec 0026): the pure decision for where a new thought is filed. Inside a user
/// folder -> that folder; from the top level / All Thoughts / Recents / a hands-free entry point ->
/// uncategorized (the store root, empty `folderPath`).
final class NewThoughtPlacementTests: XCTestCase {
    func testInsideAUserFolderFilesInThatFolder() {
        XCTAssertEqual(NewThoughtPlacement.folderPath(browsingFolder: ["Work"]), ["Work"])
    }

    func testFromTopLevelFilesUncategorized() {
        // The top level / an alias screen passes `[]` (there is no user-folder context).
        XCTAssertEqual(NewThoughtPlacement.folderPath(browsingFolder: []), [])
    }

    func testFromAnAliasFilesUncategorized() {
        // An alias screen resolves its browsing folder to `[]`, so the placement is uncategorized.
        let allThoughtsContext: [String] = []
        let recentsContext: [String] = []
        XCTAssertEqual(NewThoughtPlacement.folderPath(browsingFolder: allThoughtsContext), [])
        XCTAssertEqual(NewThoughtPlacement.folderPath(browsingFolder: recentsContext), [])
    }
}
