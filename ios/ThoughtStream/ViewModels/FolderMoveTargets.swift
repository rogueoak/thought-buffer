import Foundation

/// One destination in the "Move to folder" picker (spec 0010): a folder in the tree, shown indented
/// by its depth. "Top level" (the empty path) and "New folder..." are rendered by the sheet itself;
/// this list is every EXISTING folder, pre-order (a parent immediately before its children) and A-Z
/// among siblings, so the picker reads like the on-disk tree.
struct FolderMoveTarget: Identifiable, Hashable {
    /// The folder's full path from the root. Its last component is the display name; its count is the
    /// indent depth (1 = a top-level folder).
    let path: [String]

    /// The folder's own name (its last path component).
    var name: String { path.last ?? "" }

    /// Indent depth: a top-level folder is depth 0 for layout (one level of nesting shows one indent).
    var depth: Int { max(0, path.count - 1) }

    var id: String { path.joined(separator: "/") }
}

/// Pure builder for the move-to-folder target list (spec 0010), kept out of the view so the tree walk
/// and ordering are unit testable. Driven by a `children` closure - `store.folders(at:)` in the app,
/// a stub in a test - so it flattens the WHOLE folder tree (including empty folders, which never
/// appear in any note's `folderPath`) without the model reaching into the file system itself.
enum FolderMoveTargets {
    /// Every folder in the tree as an ordered, depth-tagged list: pre-order (parent before children),
    /// A-Z among siblings (the store already returns children sorted, but we sort again so the order is
    /// the model's guarantee, not the store's). `children([])` gives the top-level folders.
    ///
    /// `excluding` drops a subtree from the results: moving a note need not exclude anything, but the
    /// parameter keeps the builder reusable (e.g. a future move-a-folder picker must not offer a folder
    /// its own descendant). Pass `[]`-free paths; an excluded path and everything under it are omitted.
    static func all(
        children: ([String]) -> [String],
        excluding: [[String]] = []
    ) -> [FolderMoveTarget] {
        var result: [FolderMoveTarget] = []
        appendChildren(of: [], children: children, excluding: excluding, into: &result)
        return result
    }

    private static func appendChildren(
        of path: [String],
        children: ([String]) -> [String],
        excluding: [[String]],
        into result: inout [FolderMoveTarget]
    ) {
        let names = children(path).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for name in names {
            let childPath = path + [name]
            if excluding.contains(childPath) { continue }
            result.append(FolderMoveTarget(path: childPath))
            appendChildren(of: childPath, children: children, excluding: excluding, into: &result)
        }
    }
}
