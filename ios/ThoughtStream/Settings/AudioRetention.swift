import Foundation

/// How long a note's voice recording is kept (spec 0007).
///
/// The recording is raw audio, more sensitive than the transcript, so the user controls whether it
/// is written at all and how long it lives. This is the one place that policy is expressed; the
/// capture path reads it to decide whether to open the file writer, and the auto-delete sweep reads
/// it to decide which recordings have expired.
///
/// Persisted as a small string tag through `SettingsStoring` so a future case does not break stored
/// values (an unknown tag falls back to `.keep`).
enum AudioRetention: Equatable, Hashable {
    /// Keep the recording indefinitely (the default). Audio is written and never auto-deleted.
    case keep
    /// Never record. The file writer is skipped entirely, so no audio is ever written for a note.
    case transcriptOnly
    /// Keep the recording, then delete it once it is older than `days` days.
    case autoDeleteDays(Int)

    /// The default retention: keep the recording.
    static let `default`: AudioRetention = .keep

    /// Sensible bounds for the auto-delete window so a stored or typed value cannot be absurd. The
    /// max is one year: it is the same cap the Settings stepper offers, so a value can never be typed
    /// or stored above what the UI allows (they were previously inconsistent - 365 vs 3650).
    static let minDays = 1
    static let maxDays = 365

    /// Whether audio should be written during capture under this policy. Only `transcriptOnly`
    /// skips recording; `keep` and `autoDeleteDays` both record (they differ only in cleanup).
    var recordsAudio: Bool {
        switch self {
        case .keep, .autoDeleteDays: return true
        case .transcriptOnly: return false
        }
    }

    /// The number of days after which audio expires, or nil when it never auto-deletes.
    var autoDeleteDays: Int? {
        if case let .autoDeleteDays(days) = self { return days }
        return nil
    }

    // MARK: - String tag persistence

    /// Encode to a stable string tag for `UserDefaults`. `autoDeleteDays` clamps to its bounds.
    var storageTag: String {
        switch self {
        case .keep: return "keep"
        case .transcriptOnly: return "transcriptOnly"
        case let .autoDeleteDays(days):
            let clamped = min(Self.maxDays, max(Self.minDays, days))
            return "autoDelete:\(clamped)"
        }
    }

    /// Decode a stored tag. An unknown or malformed tag falls back to `.keep`, so a value written by
    /// a newer build (or a corrupt default) never crashes and defaults to the safe, expected state.
    init(storageTag tag: String) {
        switch tag {
        case "keep":
            self = .keep
        case "transcriptOnly":
            self = .transcriptOnly
        default:
            if tag.hasPrefix("autoDelete:"),
               let days = Int(tag.dropFirst("autoDelete:".count)) {
                self = .autoDeleteDays(min(Self.maxDays, max(Self.minDays, days)))
            } else {
                self = .keep
            }
        }
    }
}
