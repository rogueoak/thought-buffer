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
}

/// A `UserDefaults`-backed `SettingsStoring`. Persists the control phrase as a string and the
/// overrides as JSON. The `UserDefaults` instance is injected so tests use an isolated suite and
/// never touch the real app domain.
final class UserDefaultsSettingsStore: SettingsStoring {
    private enum Key {
        static let controlPhrase = "settings.controlPhrase"
        static let spellingOverrides = "settings.spellingOverrides"
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
            let data = try? JSONEncoder().encode(bounded)
            defaults.set(data, forKey: Key.spellingOverrides)
        }
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
