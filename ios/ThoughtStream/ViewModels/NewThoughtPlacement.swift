import Foundation

/// Where a NEW thought is filed (spec 0026), as a pure decision so the "in a folder -> that folder, else
/// uncategorized" rule is unit-tested rather than trapped in the view.
///
/// Confirmed decision: creating a thought while INSIDE a user folder files it in that folder (contextual,
/// preserving feedback 0021's contextual creation); creating one from the top level, All Thoughts, or
/// Recents leaves it UNCATEGORIZED (the store root, empty `folderPath`) - matching "it just goes under
/// recents / all" for the default case.
enum NewThoughtPlacement {
    /// The `folderPath` a new thought should be saved with, given the folder screen the user is browsing.
    ///
    /// - `browsingFolder`: the CONTEXT the new thought is created from:
    ///   - a user folder (`[name]`, one level) -> file the thought in that folder,
    ///   - the top level, an alias (All Thoughts / Recents), or a hands-free entry point (`[]`) -> file it
    ///     uncategorized at the root.
    ///
    /// Because the model is one level deep, a user folder context is always a single-component path; this
    /// keeps whatever it is handed (returning it verbatim), so a legacy deeper context - if one is ever
    /// passed - files at that same location rather than silently re-rooting.
    static func folderPath(browsingFolder: [String]) -> [String] {
        browsingFolder
    }
}
