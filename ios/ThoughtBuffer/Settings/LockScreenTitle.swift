import Foundation

/// What title a playing recording shows on the lock screen, Control Center, and CarPlay (spec 0008).
///
/// A thought's title is its first dictated line, which may be sensitive. Since playback lights up the
/// system Now Playing item on any surface the user (or a passenger, or a glance from across the room)
/// can see, this lets the user hide that line behind a fixed, generic label without giving up
/// playback controls.
///
/// Persisted as a small string tag through `SettingsStoring` so a future case does not break stored
/// values (an unknown tag falls back to `.noteTitle`, the default).
enum LockScreenTitle: String, CaseIterable, Identifiable {
    /// Show the thought's own title (its first line). The default.
    case noteTitle
    /// Show a fixed, generic label instead of the thought title, so a sensitive first line never
    /// appears on the lock screen / Control Center / CarPlay.
    case generic

    var id: String { rawValue }

    /// The default: show the thought title.
    static let `default`: LockScreenTitle = .noteTitle

    /// The fixed label published when `generic` is selected.
    static let genericTitle = "Thought Buffer recording"

    /// The Now Playing title to publish for `thought` under this setting: the thought's own title, or the
    /// fixed generic label when the user has chosen to hide it.
    func nowPlayingTitle(for thoughtTitle: String) -> String {
        switch self {
        case .noteTitle: return thoughtTitle
        case .generic: return Self.genericTitle
        }
    }

    // MARK: - String tag persistence

    /// Encode to a stable string tag for `UserDefaults`.
    var storageTag: String { rawValue }

    /// Decode a stored tag. An unknown or malformed tag falls back to `.noteTitle`, so a value
    /// written by a newer build never crashes and defaults to the safe, expected state.
    init(storageTag tag: String) {
        self = LockScreenTitle(rawValue: tag) ?? .default
    }
}
