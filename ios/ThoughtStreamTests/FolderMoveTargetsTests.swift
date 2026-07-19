import XCTest
@testable import ThoughtStream

/// `FolderMoveTargets` (spec 0010): flattens the whole folder tree into a pre-order, depth-tagged list
/// for the move-to-folder picker, driven by a `children` closure so empty folders (which never appear
/// in a thought's `folderPath`) are still offered.
final class FolderMoveTargetsTests: XCTestCase {
    /// A tree stub: maps a path to its child folder names.
    private func children(_ tree: [[String]: [String]]) -> ([String]) -> [String] {
        { path in tree[path] ?? [] }
    }

    func testFlattensPreOrderWithDepth() {
        let tree: [[String]: [String]] = [
            []: ["Work", "Home"],
            ["Work"]: ["Q1", "Q2"],
            ["Work", "Q1"]: ["Jan"],
        ]
        let targets = FolderMoveTargets.all(children: children(tree))
        // Pre-order, A-Z siblings: Home, Work, Work/Q1, Work/Q1/Jan, Work/Q2.
        XCTAssertEqual(targets.map(\.path), [
            ["Home"],
            ["Work"],
            ["Work", "Q1"],
            ["Work", "Q1", "Jan"],
            ["Work", "Q2"],
        ])
    }

    func testDepthMatchesNesting() {
        let tree: [[String]: [String]] = [
            []: ["Work"],
            ["Work"]: ["Q1"],
            ["Work", "Q1"]: ["Jan"],
        ]
        let targets = FolderMoveTargets.all(children: children(tree))
        XCTAssertEqual(targets.map(\.depth), [0, 1, 2])
        XCTAssertEqual(targets.map(\.name), ["Work", "Q1", "Jan"])
    }

    func testEmptyFolderIsStillOffered() {
        // "Empty" has no thoughts anywhere, but the children closure reports it, so it must appear.
        let tree: [[String]: [String]] = [[]: ["Empty"]]
        let targets = FolderMoveTargets.all(children: children(tree))
        XCTAssertEqual(targets.map(\.path), [["Empty"]])
    }

    func testSiblingsAreSortedCaseInsensitive() {
        let tree: [[String]: [String]] = [[]: ["banana", "Apple", "Cherry"]]
        let targets = FolderMoveTargets.all(children: children(tree))
        XCTAssertEqual(targets.map(\.name), ["Apple", "banana", "Cherry"])
    }

    func testExcludingDropsASubtree() {
        let tree: [[String]: [String]] = [
            []: ["Work", "Home"],
            ["Work"]: ["Q1"],
        ]
        let targets = FolderMoveTargets.all(children: children(tree), excluding: [["Work"]])
        // Work and everything under it is gone; only Home remains.
        XCTAssertEqual(targets.map(\.path), [["Home"]])
    }

    func testEmptyTreeProducesNoTargets() {
        let targets = FolderMoveTargets.all(children: children([:]))
        XCTAssertTrue(targets.isEmpty)
    }
}
