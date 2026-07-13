import Foundation

/// The app's user-configurable settings: the assistant's control phrase and the spelling
/// overrides. A reference type so the SwiftUI Settings screen edits the same instance the
/// composition root reads when it builds a session's text processor.
///
/// Local only: backed by `UserDefaults` in production (`UserDefaultsSettingsStore`). No cloud
/// sync or per-note settings (see spec 0006). Changes apply to the NEXT dictation session, since
/// the processor is built per session from these values.
protocol SettingsStoring: AnyObject {
    /// The word that must lead a voice command (default "Mira"). Reads back validated: an empty,
    /// whitespace-only, or over-long value falls back to `MiraTextProcessor.defaultControlWord`.
    /// The setter may store any string; validation happens on read so "clear the field" resets.
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

    /// A sensible upper bound on the control phrase. A name longer than this is almost certainly a
    /// mistake (or a whole sentence pasted in), so it falls back to the default rather than making
    /// every command start with a paragraph.
    static let maxControlPhraseLength = 32

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var controlPhrase: String {
        get {
            let raw = defaults.string(forKey: Key.controlPhrase) ?? ""
            return Self.validatedControlPhrase(raw)
        }
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
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: Key.spellingOverrides)
        }
    }

    /// Trim, then fall back to the default control word if the result is empty or too long. Pure so
    /// tests can exercise validation directly.
    static func validatedControlPhrase(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxControlPhraseLength else {
            return MiraTextProcessor.defaultControlWord
        }
        return trimmed
    }
}
