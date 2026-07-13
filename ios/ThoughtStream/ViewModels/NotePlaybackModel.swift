import Foundation
import SwiftUI

/// Resolves and validates a note's recording URL off the main actor (spec 0007).
///
/// Navigation must stay smooth: on iCloud, checking whether a recording is present is a coordinated
/// read that can block on the sync daemon, so it must never run on the main actor while the user is
/// pushing into a note. This seam lets `NotePlaybackModel` do that resolution lazily, at play time,
/// off-main - and lets a future CarPlay Now Playing surface re-validate the URL mid-session (a
/// recording can be swept or synced away between sessions). Returns nil when the note has no audio or
/// the file is not present on disk, so playback never points at a missing file.
protocol AudioURLResolving: Sendable {
    /// The playable, on-disk URL of the note's recording, or nil when it has no audio or the file is
    /// absent. Called off the main actor; may block on coordinated IO.
    func resolveAudioURL(for noteID: UUID, audioFileName: String?) -> URL?
}

/// The production resolver: a note store plus the coordinated presence check it already exposes.
struct StoreAudioURLResolver: AudioURLResolving {
    let store: NoteStoring

    func resolveAudioURL(for noteID: UUID, audioFileName: String?) -> URL? {
        // No claimed recording (older note, transcript-only, edited-away): nothing to resolve.
        guard audioFileName != nil else { return nil }
        // Coordinated presence check (on iCloud) so a synced-but-not-downloaded recording is not
        // mis-reported; a bare URL alone could point at a file that was swept or not yet synced.
        guard store.audioExists(for: noteID) else { return nil }
        return store.audioURL(for: noteID)
    }
}

/// Drives simple play / stop of a saved note's recording from the detail view (spec 0007).
///
/// Keeps the detail view presentational: it owns an `AudioNotePlayer`, tracks whether playback is
/// running so the button can toggle, and resets on finish. Playback here is the WHOLE note (from the
/// start of the recording to the end), which is why it plays with no duration. Scrubbing, per
/// paragraph play, and rate controls are out of scope for this milestone.
///
/// The recording URL is resolved LAZILY, at `toggle()`/`play()` time, off the main actor - never
/// during navigation. That keeps pushing into a note smooth even on iCloud (where presence is a
/// coordinated, potentially blocking read) and lets the URL be re-validated on every play, so a
/// future CarPlay Now Playing session sees a recording that was swept or synced away mid-session
/// rather than a stale URL. Because resolution is async, `canPlay` is optimistic (the note claims a
/// recording); an actual missing file simply leaves the model idle after a play attempt.
@MainActor
final class NotePlaybackModel: ObservableObject {
    /// True while the recording is playing, so the view shows Stop instead of Play.
    @Published private(set) var isPlaying = false

    /// The note's id and its claimed audio filename, used to resolve the recording lazily at play
    /// time. `audioFileName` is nil when the note has no recording (older notes, transcript-only, or
    /// auto-deleted), which hides the play affordance.
    private let noteID: UUID
    private let audioFileName: String?
    private let resolver: AudioURLResolving
    private let player: AudioNotePlayer

    /// The in-flight resolve+play, tracked so a rapid second toggle cancels the first rather than
    /// racing two plays.
    private var pendingPlay: Task<Void, Never>?

    init(
        noteID: UUID,
        audioFileName: String?,
        resolver: AudioURLResolving,
        player: AudioNotePlayer? = nil
    ) {
        self.noteID = noteID
        self.audioFileName = audioFileName
        self.resolver = resolver
        self.player = player ?? SystemAudioNotePlayer()
        self.player.onFinish = { [weak self] in
            self?.isPlaying = false
        }
    }

    /// Convenience for a `Note`: resolve through the given store lazily at play time.
    convenience init(note: Note, store: NoteStoring, player: AudioNotePlayer? = nil) {
        self.init(
            noteID: note.id,
            audioFileName: note.audioFileName,
            resolver: StoreAudioURLResolver(store: store),
            player: player
        )
    }

    /// Whether the note claims a recording, so the view offers the play affordance. Optimistic: the
    /// file's actual presence is confirmed off-main at play time (a missing file leaves the model
    /// idle), which keeps navigation off the coordinated presence check.
    var canPlay: Bool { audioFileName != nil }

    /// Toggle playback: resolve the recording off-main then start from the top, or stop if already
    /// playing (or resolving).
    func toggle() {
        if isPlaying || pendingPlay != nil {
            stop()
            return
        }
        guard audioFileName != nil else { return }

        // Resolve + validate the URL OFF the main actor (coordinated presence can block), then start
        // playback back on the main actor. Optimistically flip to "playing" so the button responds
        // immediately; a nil URL or a failed play clears it.
        isPlaying = true
        let noteID = noteID
        let audioFileName = audioFileName
        let resolver = resolver
        pendingPlay = Task { [weak self] in
            let url = await Task.detached {
                resolver.resolveAudioURL(for: noteID, audioFileName: audioFileName)
            }.value
            guard !Task.isCancelled else { return }
            self?.startPlayback(url: url)
        }
    }

    /// Start playback of a resolved URL on the main actor. A nil or unplayable URL leaves the model
    /// idle rather than stuck "playing".
    private func startPlayback(url: URL?) {
        pendingPlay = nil
        guard let url, player.play(url: url, from: 0, duration: nil) else {
            isPlaying = false
            return
        }
        isPlaying = true
    }

    /// Stop playback if it is running (used when the view disappears), and cancel a pending resolve.
    func stop() {
        pendingPlay?.cancel()
        pendingPlay = nil
        if isPlaying {
            player.stop()
            // `player.stop()` fires `onFinish`, which already clears `isPlaying`; setting it here too
            // covers the resolving-but-not-yet-playing case (no player call has been made yet).
            isPlaying = false
        }
    }
}
