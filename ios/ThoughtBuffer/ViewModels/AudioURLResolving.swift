import Foundation

/// Resolves and validates a thought's recording URL off the main actor (spec 0007).
///
/// Navigation must stay smooth: on iCloud, checking whether a recording is present is a coordinated
/// read that can block on the sync daemon, so it must never run on the main actor while the user is
/// pushing into a thought. This seam lets `ThoughtPlaybackController` do that resolution lazily, at play
/// time, off-main - and lets the CarPlay Now Playing surface re-validate the URL mid-session (a
/// recording can be swept or synced away between sessions). Returns nil when the thought has no audio or
/// the file is not present on disk, so playback never points at a missing file.
protocol AudioURLResolving: Sendable {
    /// The playable, on-disk URL of the thought's recording, or nil when it has no audio or the file is
    /// absent. Called off the main actor; may block on coordinated IO.
    func resolveAudioURL(for thoughtID: UUID, audioFileName: String?) -> URL?
}

/// The production resolver: a thought store plus the coordinated presence check it already exposes.
struct StoreAudioURLResolver: AudioURLResolving {
    let store: ThoughtStoring

    func resolveAudioURL(for thoughtID: UUID, audioFileName: String?) -> URL? {
        // No claimed recording (older thought, transcript-only, edited-away): nothing to resolve.
        guard audioFileName != nil else { return nil }
        // Coordinated presence check (on iCloud) so a synced-but-not-downloaded recording is not
        // mis-reported; a bare URL alone could point at a file that was swept or not yet synced.
        guard store.audioExists(for: thoughtID) else { return nil }
        return store.audioURL(for: thoughtID)
    }
}
