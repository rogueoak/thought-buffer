import Foundation

/// How the Thoughts list (top level and inside any folder) is ordered (spec 0010). The chosen order
/// is persisted globally and applied everywhere; PR B wires the toolbar menu and the `SettingsStoring`
/// persistence, while PR A owns the pure sort so the ordering is unit-testable without any UI.
///
/// The sort is a value-in / value-out pure function over `[Thought]`, so it can be reused for the thoughts
/// list and (in PR B) for folders sorted among thoughts by the same key.
enum ThoughtSortOrder: String, CaseIterable, Codable, Sendable {
    /// Newest thought first (the app's original, default order).
    case newest
    /// Oldest thought first.
    case oldest
    /// By title, A to Z (case-insensitive, locale-aware).
    case titleAZ
    /// By title, Z to A (case-insensitive, locale-aware).
    case titleZA

    /// The default order (newest first), matching the app's original flat stream.
    static var `default`: ThoughtSortOrder { .newest }

    // MARK: - String tag persistence (PR B)

    /// A stable string tag for `SettingsStoring` persistence. This is deliberately its own name (not
    /// just `rawValue`) so the persisted contract is explicit and matches the other settings types
    /// (`AudioRetention`, `LockScreenTitle`): the tag is the identity we promise to keep stable across
    /// builds, and decoding an unknown tag falls back to `.default` rather than crashing.
    var storageTag: String { rawValue }

    /// Decode a stored tag. An unknown or absent tag falls back to `.default` (newest first), so a
    /// value written by a newer build (or a corrupt default) never fails to decode.
    init(tag: String) {
        self = ThoughtSortOrder(rawValue: tag) ?? .default
    }

    /// A short, user-facing label for the sort menu (PR B).
    var label: String {
        switch self {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .titleAZ: return "Title A-Z"
        case .titleZA: return "Title Z-A"
        }
    }

    /// The minimal fields the ordering compares: a title, a date, and a deterministic tie-break
    /// string. Single-sourced here so both thoughts and (in PR B) folders can be ordered by the SAME
    /// key: a thought builds a key from `(title, createdAt, id)`, while a folder builds one from
    /// `(name, newest-thought date, name-or-id)`. Keeping the comparator over `SortKey` rather than over
    /// `Thought` is what lets folders be sorted among thoughts without a second copy of the ordering rules.
    struct SortKey {
        let title: String
        let date: Date
        let tieBreak: String
    }

    /// Whether `a` should sort before `b` under this order. This is the single source of truth for
    /// the ordering; `sort(_:)` builds `SortKey`s from thoughts and defers to it, and PR B reuses it for
    /// folders. The order is TOTAL and deterministic: a secondary (and final tie-break) key breaks
    /// ties so equal primary keys never reorder run to run.
    ///
    /// - Date orders (`newest`/`oldest`) tie-break by title A-Z, then by `tieBreak`.
    /// - Title orders (`titleAZ`/`titleZA`) tie-break by date (newest first), then by `tieBreak`.
    func areInIncreasingOrder(_ a: SortKey, _ b: SortKey) -> Bool {
        switch self {
        case .newest:
            if a.date != b.date { return a.date > b.date }
            return Self.titleTieBreak(a, b, ascending: true)
        case .oldest:
            if a.date != b.date { return a.date < b.date }
            return Self.titleTieBreak(a, b, ascending: true)
        case .titleAZ:
            let cmp = Self.compareTitles(a, b)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return Self.dateTieBreak(a, b)
        case .titleZA:
            let cmp = Self.compareTitles(a, b)
            if cmp != .orderedSame { return cmp == .orderedDescending }
            return Self.dateTieBreak(a, b)
        }
    }

    /// The `SortKey` for a thought: title and date are the thought's own; the tie-break is the id string so
    /// two otherwise-equal thoughts have one fixed order.
    static func sortKey(for thought: Thought) -> SortKey {
        SortKey(title: thought.title, date: thought.createdAt, tieBreak: thought.id.uuidString)
    }

    /// Sort `thoughts` by this order, returning a new array. Builds a `SortKey` per thought and defers to
    /// `areInIncreasingOrder`, so thoughts and folders (PR B) share one ordering. STABLE for equal
    /// primary keys via the key's tie-break.
    func sort(_ thoughts: [Thought]) -> [Thought] {
        thoughts.sorted { areInIncreasingOrder(Self.sortKey(for: $0), Self.sortKey(for: $1)) }
    }

    /// Case-insensitive, locale-aware title comparison, the primary key of the title orders.
    private static func compareTitles(_ lhs: SortKey, _ rhs: SortKey) -> ComparisonResult {
        lhs.title.localizedCaseInsensitiveCompare(rhs.title)
    }

    /// Tie-break by title ascending, then tie-break string, so an equal-date pair has one fixed order.
    private static func titleTieBreak(_ lhs: SortKey, _ rhs: SortKey, ascending: Bool) -> Bool {
        let cmp = compareTitles(lhs, rhs)
        if cmp != .orderedSame { return ascending ? cmp == .orderedAscending : cmp == .orderedDescending }
        return lhs.tieBreak < rhs.tieBreak
    }

    /// Tie-break by date (newest first), then tie-break string, so an equal-title pair has one fixed
    /// order.
    private static func dateTieBreak(_ lhs: SortKey, _ rhs: SortKey) -> Bool {
        if lhs.date != rhs.date { return lhs.date > rhs.date }
        return lhs.tieBreak < rhs.tieBreak
    }
}
