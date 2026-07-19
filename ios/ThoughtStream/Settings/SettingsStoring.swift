import Foundation

/// The app's user-configurable settings: the assistant's control phrase and the spelling
/// overrides. A reference type so the SwiftUI Settings screen edits the same instance the
/// composition root reads when it builds a session's text processor.
///
/// Local only: backed by `UserDefaults` in production (`UserDefaultsSettingsStore`). No cloud
/// sync or per-note settings (see spec 0006). Changes apply to the NEXT dictation session, since
/// the processor is built per session from these values.
protocol SettingsStoring: AnyObject {
    /// The word that must lead a voice command (default "Mira"). Reads back validated through the
    /// shared `ControlPhrase` seam: trimmed, collapsed to its first alphanumeric token (the parser
    /// matches a single token), and falling back to "Mira" when empty or over-long. The setter may
    /// store any string; validation happens on read so "clear the field" resets.
    var controlPhrase: String { get set }

    /// The ordered list of spelling fixes applied to dictated text before commit.
    var spellingOverrides: [SpellingOverride] { get set }

    /// How long a note's voice recording is kept (spec 0007). Defaults to `.keep`. The capture path
    /// reads this to decide whether to record at all; the auto-delete sweep reads it to expire old
    /// recordings. Persisted as a small string tag so an unknown value falls back to `.keep`.
    var audioRetention: AudioRetention { get set }

    /// What title a playing recording shows on the lock screen / Control Center / CarPlay (spec
    /// 0008). Defaults to `.noteTitle` (the note's own first line); `.generic` hides it behind a
    /// fixed label so a sensitive first line does not appear on a system Now Playing surface.
    /// Persisted as a small string tag so an unknown value falls back to `.noteTitle`.
    var lockScreenTitle: LockScreenTitle { get set }

    /// How the Thoughts list (top level and inside any folder) is ordered (spec 0010). Defaults to
    /// `.newest` (the app's original flat stream). The sort menu binds to this and the list re-sorts
    /// live; the choice is persisted globally so it survives a launch. Persisted as a small string
    /// tag so an unknown value falls back to `.newest`.
    var noteSortOrder: NoteSortOrder { get set }
}

/// A `UserDefaults`-backed `SettingsStoring`. Persists the control phrase as a string and the
/// overrides as JSON. The `UserDefaults` instance is injected so tests use an isolated suite and
/// never touch the real app domain.
final class UserDefaultsSettingsStore: SettingsStoring {
    private enum Key {
        static let controlPhrase = "settings.controlPhrase"
        static let spellingOverrides = "settings.spellingOverrides"
        static let audioRetention = "settings.audioRetention"
        static let lockScreenTitle = "settings.lockScreenTitle"
        static let noteSortOrder = "settings.noteSortOrder"
    }

    /// Bounds on the persisted overrides so a stuck field or a paste cannot grow `UserDefaults`
    /// without limit or make the per-segment rescan expensive. Rows past the cap and characters
    /// past the field length are dropped on write.
    static let maxOverrideCount = 200
    static let maxOverrideFieldLength = 128

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var controlPhrase: String {
        // Validation is a shared seam (`ControlPhrase`) so the store and the Settings UI agree, and
        // so a multi-word or punctuated phrase reduces to the single token the parser matches. The
        // setter stores raw (so "clear the field" resets); the getter validates.
        get { ControlPhrase.validated(defaults.string(forKey: Key.controlPhrase) ?? "") }
        set { defaults.set(newValue, forKey: Key.controlPhrase) }
    }

    var spellingOverrides: [SpellingOverride] {
        get {
            guard let data = defaults.data(forKey: Key.spellingOverrides),
                  let decoded = try? JSONDecoder().decode([SpellingOverride].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            let bounded = Self.bounded(newValue)
            // `try?` yields nil only if encoding `[SpellingOverride]` fails, which cannot happen for
            // this fixed, all-`String`/`UUID` Codable type. If it somehow did, `defaults.set` with
            // nil clears the key, so the getter falls back to `[]` - the same safe empty state as a
            // fresh install, never a crash and never stale data.
            let data = try? JSONEncoder().encode(bounded)
            defaults.set(data, forKey: Key.spellingOverrides)
        }
    }

    var audioRetention: AudioRetention {
        // Stored as a small string tag so a value written by a newer build never fails to decode;
        // an absent or unknown tag falls back to `.keep` (the safe default: keeping is what a fresh
        // install does today, and the transcript is unaffected either way).
        get {
            guard let tag = defaults.string(forKey: Key.audioRetention) else { return .default }
            return AudioRetention(storageTag: tag)
        }
        set { defaults.set(newValue.storageTag, forKey: Key.audioRetention) }
    }

    var lockScreenTitle: LockScreenTitle {
        // Stored as a small string tag so a value written by a newer build never fails to decode;
        // an absent or unknown tag falls back to `.noteTitle` (the safe default: showing the note's
        // own title is the current behavior).
        get {
            guard let tag = defaults.string(forKey: Key.lockScreenTitle) else { return .default }
            return LockScreenTitle(storageTag: tag)
        }
        set { defaults.set(newValue.storageTag, forKey: Key.lockScreenTitle) }
    }

    var noteSortOrder: NoteSortOrder {
        // Stored as a small string tag so a value written by a newer build never fails to decode; an
        // absent or unknown tag falls back to `.newest` (the app's original flat stream order).
        get {
            guard let tag = defaults.string(forKey: Key.noteSortOrder) else { return .default }
            return NoteSortOrder(tag: tag)
        }
        set { defaults.set(newValue.storageTag, forKey: Key.noteSortOrder) }
    }

    /// Cap the row count and per-field length so persistence and the per-segment rescan stay
    /// bounded regardless of input. Preserves order and identity.
    static func bounded(_ overrides: [SpellingOverride]) -> [SpellingOverride] {
        overrides.prefix(maxOverrideCount).map { override in
            SpellingOverride(
                id: override.id,
                from: String(override.from.prefix(maxOverrideFieldLength)),
                to: String(override.to.prefix(maxOverrideFieldLength))
            )
        }
    }
}
