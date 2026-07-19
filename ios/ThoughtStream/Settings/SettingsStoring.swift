import Foundation

/// The app's user-configurable settings: the assistant's control phrase and the spelling
/// overrides. A reference type so the SwiftUI Settings screen edits the same instance the
/// composition root reads when it builds a session's text processor.
///
/// Local only: backed by `UserDefaults` in production (`UserDefaultsSettingsStore`). No cloud
/// sync or per-thought settings (see spec 0006). Changes apply to the NEXT dictation session, since
/// the processor is built per session from these values.
protocol SettingsStoring: AnyObject {
    /// The word that must lead a voice command (default "Mira"). Reads back validated through the
    /// shared `ControlPhrase` seam: trimmed, collapsed to its first alphanumeric token (the parser
    /// matches a single token), and falling back to "Mira" when empty or over-long. The setter may
    /// store any string; validation happens on read so "clear the field" resets.
    var controlPhrase: String { get set }

    /// The ordered list of alias trigger words (spec 0018): extra single-token spellings that also
    /// fire command mode, so a recognizer mishearing of the control word ("mirror" for "Mira") still
    /// triggers a command instead of being written into the thought. Reads back validated through the
    /// shared `ControlPhrase.validatedAliases` seam: each alias trimmed to a single token, empty and
    /// multi-word entries dropped, de-duplicated case-insensitively, and never colliding with the
    /// primary word. A fresh install (nothing ever stored) reads back `ControlPhrase.defaultAliases`
    /// so common mishearings are tolerated out of the box; once the user edits the list (even to
    /// empty) their choice is what persists. The setter may store any array; validation happens on
    /// read, and validation is against the CURRENT `controlPhrase` so an alias can never shadow it.
    var controlPhraseAliases: [String] { get set }

    /// The ordered list of spelling fixes applied to dictated text before commit.
    var spellingOverrides: [SpellingOverride] { get set }

    /// How long a thought's voice recording is kept (spec 0007). Defaults to `.keep`. The capture path
    /// reads this to decide whether to record at all; the auto-delete sweep reads it to expire old
    /// recordings. Persisted as a small string tag so an unknown value falls back to `.keep`.
    var audioRetention: AudioRetention { get set }

    /// What title a playing recording shows on the lock screen / Control Center / CarPlay (spec
    /// 0008). Defaults to `.noteTitle` (the thought's own first line); `.generic` hides it behind a
    /// fixed label so a sensitive first line does not appear on a system Now Playing surface.
    /// Persisted as a small string tag so an unknown value falls back to `.noteTitle`.
    var lockScreenTitle: LockScreenTitle { get set }

    /// How the Thoughts list (top level and inside any folder) is ordered (spec 0010). Defaults to
    /// `.newest` (the app's original flat stream). The sort menu binds to this and the list re-sorts
    /// live; the choice is persisted globally so it survives a launch. Persisted as a small string
    /// tag so an unknown value falls back to `.newest`.
    var thoughtSortOrder: ThoughtSortOrder { get set }

    /// Whether to refine the transcript (spec 0016): remove filler words live during dictation, and
    /// reflow continuation lines when an edited thought is saved. Defaults to `true`. It NEVER changes the
    /// recorded audio - only the transcript text. When off, dictation commits verbatim (the pre-0016
    /// behavior) and no reflow runs on save. The filler stage is built into the per-session text
    /// processor from this value, so a change takes effect on the next dictation session, like the
    /// control phrase.
    var refineTranscript: Bool { get set }

    /// Whether to trim dead air from a NEW recording on save (spec 0019). Defaults to `true`. When on,
    /// silences longer than `SilenceTrimmer.minPauseSeconds` are cut to a short breath gap and the
    /// recording is REPLACED atomically (the removed silence is not retained); paragraph timings are
    /// remapped so playback still seeks correctly. It only ever changes the AUDIO of a new recording -
    /// the transcript text is untouched. When OFF, NO code path touches the audio: recordings are the
    /// byte-for-byte untrimmed capture (the pre-0019 behavior). Applies at save time, so a change takes
    /// effect on the next recording, not one already saved.
    var trimSilence: Bool { get set }
}

/// A `UserDefaults`-backed `SettingsStoring`. Persists the control phrase as a string and the
/// overrides as JSON. The `UserDefaults` instance is injected so tests use an isolated suite and
/// never touch the real app domain.
final class UserDefaultsSettingsStore: SettingsStoring {
    private enum Key {
        static let controlPhrase = "settings.controlPhrase"
        static let controlPhraseAliases = "settings.controlPhraseAliases"
        static let spellingOverrides = "settings.spellingOverrides"
        static let audioRetention = "settings.audioRetention"
        static let lockScreenTitle = "settings.lockScreenTitle"
        static let thoughtSortOrder = "settings.noteSortOrder"
        static let refineTranscript = "settings.refineTranscript"
        static let trimSilence = "settings.trimSilence"
    }

    /// Bounds on the persisted overrides so a stuck field or a paste cannot grow `UserDefaults`
    /// without limit or make the per-segment rescan expensive. Rows past the cap and characters
    /// past the field length are dropped on write.
    static let maxOverrideCount = 200
    static let maxOverrideFieldLength = 128

    /// Bound on the persisted alias list so a stuck field cannot grow `UserDefaults` without limit
    /// or make the per-segment trigger set expensive. Rows past the cap are dropped on write; the
    /// per-alias length is already capped by `ControlPhrase.maxLength` on read.
    static let maxAliasCount = 50

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

    var controlPhraseAliases: [String] {
        // A fresh install (key never written) reads back the default alias set so common mishearings
        // are tolerated out of the box - like `refineTranscript`, presence is checked explicitly so an
        // absent key means "default", not "empty". Once the user edits (even to an empty list) the
        // stored array is what persists. On read, the raw list is validated against the CURRENT
        // control phrase through the shared seam, so an alias can never shadow the primary word and a
        // bad entry (empty, multi-word, duplicate) is dropped. The store persists the raw list (bounded)
        // so the UI can round-trip what the user typed and re-validate against a later primary change.
        get {
            guard let raw = defaults.stringArray(forKey: Key.controlPhraseAliases) else {
                return ControlPhrase.defaultAliases
            }
            return ControlPhrase.validatedAliases(raw, primaryWord: controlPhrase)
        }
        set { defaults.set(Array(newValue.prefix(Self.maxAliasCount)), forKey: Key.controlPhraseAliases) }
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
        // an absent or unknown tag falls back to `.noteTitle` (the safe default: showing the thought's
        // own title is the current behavior).
        get {
            guard let tag = defaults.string(forKey: Key.lockScreenTitle) else { return .default }
            return LockScreenTitle(storageTag: tag)
        }
        set { defaults.set(newValue.storageTag, forKey: Key.lockScreenTitle) }
    }

    var thoughtSortOrder: ThoughtSortOrder {
        // Stored as a small string tag so a value written by a newer build never fails to decode; an
        // absent or unknown tag falls back to `.newest` (the app's original flat stream order).
        get {
            guard let tag = defaults.string(forKey: Key.thoughtSortOrder) else { return .default }
            return ThoughtSortOrder(tag: tag)
        }
        set { defaults.set(newValue.storageTag, forKey: Key.thoughtSortOrder) }
    }

    var refineTranscript: Bool {
        // Defaults to `true`. `bool(forKey:)` returns false for a MISSING key, which would flip the
        // default the wrong way on a fresh install, so presence is checked explicitly: an absent key
        // reads as the `true` default, and only an explicitly stored value overrides it.
        get {
            guard defaults.object(forKey: Key.refineTranscript) != nil else { return true }
            return defaults.bool(forKey: Key.refineTranscript)
        }
        set { defaults.set(newValue, forKey: Key.refineTranscript) }
    }

    var trimSilence: Bool {
        // Defaults to `true` (spec 0019). Presence-checked like `refineTranscript` so a fresh install
        // reads ON rather than the `bool(forKey:)` false default, and only an explicitly stored value
        // (the user turning it off) overrides it.
        get {
            guard defaults.object(forKey: Key.trimSilence) != nil else { return true }
            return defaults.bool(forKey: Key.trimSilence)
        }
        set { defaults.set(newValue, forKey: Key.trimSilence) }
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
