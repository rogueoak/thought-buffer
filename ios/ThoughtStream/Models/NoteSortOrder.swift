import Foundation

/// How the Thoughts list (top level and inside any folder) is ordered (spec 0010). The chosen order
/// is persisted globally and applied everywhere; PR B wires the toolbar menu and the `SettingsStoring`
/// persistence, while PR A owns the pure sort so the ordering is unit-testable without any UI.
///
/// The sort is a value-in / value-out pure function over `[Note]`, so it can be reused for the notes
/// list and (in PR B) for folders sorted among notes by the same key.
enum NoteSortOrder: String, CaseIterable, Codable, Sendable {
    /// Newest note first (the app's original, default order).
    case newest
    /// Oldest note first.
    case oldest
    /// By title, A to Z (case-insensitive, locale-aware).
    case titleAZ
    /// By title, Z to A (case-insensitive, locale-aware).
    case titleZA

    /// The default order (newest first), matching the app's original flat stream.
    static var `default`: NoteSortOrder { .newest }

    /// A short, user-facing label for the sort menu (PR B).
    var label: String {
        switch self {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .titleAZ: return "Title A-Z"
        case .titleZA: return "Title Z-A"
        }
    }

    /// Sort `notes` by this order, returning a new array. The sort is STABLE for equal primary keys:
    /// a secondary key breaks ties deterministically so two notes with the same timestamp (or the same
    /// title) never reorder run to run.
    ///
    /// - Date orders (`newest`/`oldest`) tie-break by title A-Z, then by id, so equal-timestamp notes
    ///   have one fixed order.
    /// - Title orders (`titleAZ`/`titleZA`) tie-break by `createdAt` (newest first), then by id, so
    ///   same-titled notes have one fixed order.
    func sort(_ notes: [Note]) -> [Note] {
        notes.sorted { lhs, rhs in
            switch self {
            case .newest:
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return Self.titleTieBreak(lhs, rhs, ascending: true)
            case .oldest:
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return Self.titleTieBreak(lhs, rhs, ascending: true)
            case .titleAZ:
                let cmp = Self.compareTitles(lhs, rhs)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return Self.dateTieBreak(lhs, rhs)
            case .titleZA:
                let cmp = Self.compareTitles(lhs, rhs)
                if cmp != .orderedSame { return cmp == .orderedDescending }
                return Self.dateTieBreak(lhs, rhs)
            }
        }
    }

    /// Case-insensitive, locale-aware title comparison, the primary key of the title orders.
    private static func compareTitles(_ lhs: Note, _ rhs: Note) -> ComparisonResult {
        lhs.title.localizedCaseInsensitiveCompare(rhs.title)
    }

    /// Tie-break by title ascending, then id, so an equal-timestamp pair has one fixed order.
    private static func titleTieBreak(_ lhs: Note, _ rhs: Note, ascending: Bool) -> Bool {
        let cmp = compareTitles(lhs, rhs)
        if cmp != .orderedSame { return ascending ? cmp == .orderedAscending : cmp == .orderedDescending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Tie-break by date (newest first), then id, so an equal-title pair has one fixed order.
    private static func dateTieBreak(_ lhs: Note, _ rhs: Note) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
