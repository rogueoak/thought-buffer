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
}

/// A `UserDefaults`-backed `SettingsStoring`. Persists the control phrase as a string and the
/// overrides as JSON. The `UserDefaults` instance is injected so tests use an isolated suite and
/// never touch the real app domain.
final class UserDefaultsSettingsStore: SettingsStoring {
    private enum Key {
        static let controlPhrase = "settings.controlPhrase"
        static let spellingOverrides = "settings.spellingOverrides"
        static let audioRetention = "settings.audioRetention"
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
