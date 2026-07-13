import Foundation
import SwiftUI

/// Resolves and validates a note's recording URL off the main actor (spec 0007).
///
/// Navigation must stay smooth: on iCloud, checking whether a recording is present is a coordinated
/// read that can block on the sync daemon, so it must never run on the main actor while the user is
/// pushing into a note. This seam lets `NotePlaybackController` do that resolution lazily, at play
/// time, off-main - and lets the CarPlay Now Playing surface re-validate the URL mid-session (a
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
/// A thin main-actor projection over the shared `NotePlaybackController` (spec 0008): the detail
/// view keeps its simple play / stop button, but the actual audio path - the player, the lazy
/// off-main URL resolution, and the system Now Playing / remote-command wiring - lives in the one
/// shared controller that CarPlay also drives, so there is exactly one place that talks to the
/// `AudioNotePlayer` and one writer of `MPNowPlayingInfoCenter`. Playing a note from the detail view
/// therefore also lights up the lock screen and Control Center.
///
/// Playback here is the WHOLE note (from the start of the recording to the end). Scrubbing, per
/// paragraph play, and rate controls are out of scope for this milestone.
@MainActor
final class NotePlaybackModel: ObservableObject {
    /// True while the recording is playing, so the view shows Stop instead of Play. Mirrors the
    /// shared controller's `isPlaying`.
    @Published private(set) var isPlaying = false

    /// The note this model plays. The full value is needed so the controller can title Now Playing
    /// and read the recording duration; the detail view already holds it.
    private let note: Note
    private let controller: NotePlaybackController
    /// The controller drives more than this note over its lifetime (CarPlay may load others), so the
    /// model mirrors `isPlaying` only while ITS note is the loaded one.
    private var isObserving = false
    /// This model's registration on the shared controller's transport multicast, dropped on deinit so
    /// a detail view coming and going does not leave stale observers on the long-lived shared
    /// controller. Nil until `beginObserving`.
    private var observerToken: NotePlaybackController.TransportObserverToken?

    init(note: Note, controller: NotePlaybackController) {
        self.note = note
        self.controller = controller
    }

    deinit {
        // The controller is shared and outlives this model; drop our observer so it does not accrue
        // dead entries. `nonisolated(unsafe)` is unnecessary - deinit hops are handled by the token
        // capture; the removal is a plain dictionary delete on the main-actor controller.
        if let observerToken {
            let controller = controller
            Task { @MainActor in controller.removeTransportObserver(observerToken) }
        }
    }

    /// Test-support convenience: build a private controller from just the id + audio reference.
    /// Production callers hold a full `Note` and use the `note:` initializer (so Now Playing gets a
    /// real title / duration); this exists for the id-only playback tests. Resolves through the given
    /// resolver.
    convenience init(
        noteID: UUID,
        audioFileName: String?,
        resolver: AudioURLResolving,
        player: AudioNotePlayer? = nil
    ) {
        // A minimal note carrying only the id and audio reference is enough for the resolver; the fake
        // title / zero duration never reach production Now Playing because no production caller uses
        // this path.
        let note = Note(
            id: noteID,
            title: "",
            paragraphs: [],
            createdAt: Date(),
            audioFileName: audioFileName,
            timings: audioFileName == nil ? [] : [ParagraphTiming(start: 0, duration: 0)]
        )
        self.init(note: note, controller: NotePlaybackController(resolver: resolver, player: player))
    }

    /// Convenience for a `Note`: resolve through the given store lazily at play time.
    convenience init(note: Note, store: NoteStoring, player: AudioNotePlayer? = nil) {
        self.init(
            note: note,
            controller: NotePlaybackController(
                resolver: StoreAudioURLResolver(store: store),
                player: player
            )
        )
    }

    /// Whether the note claims a recording, so the view offers the play affordance. Optimistic: the
    /// file's actual presence is confirmed off-main at play time (a missing file leaves the model
    /// idle), which keeps navigation off the coordinated presence check.
    var canPlay: Bool { note.audioFileName != nil }

    /// Toggle playback through the shared controller:
    /// - playing this note -> stop;
    /// - this note is loaded but PAUSED (another surface, or the lock screen, paused it) -> resume
    ///   from the paused position rather than restarting from the top;
    /// - otherwise -> start this note's recording from the top.
    func toggle() {
        beginObserving()
        if isPlaying {
            controller.stop()
        } else if controller.isLoaded(note) && controller.isPaused {
            controller.resume()
        } else {
            controller.play(note: note)
        }
        syncFromController()
    }

    /// Stop playback if it is running (used when the view disappears).
    func stop() {
        if controller.isLoaded(note) {
            controller.stop()
        }
        syncFromController()
    }

    // MARK: - Private

    /// Start mirroring the controller's transport state onto `isPlaying`. Wired lazily and through the
    /// multi-observer API so this model coexists with any other surface (CarPlay) observing the same
    /// shared controller rather than clobbering its callback.
    private func beginObserving() {
        guard !isObserving else { return }
        isObserving = true
        observerToken = controller.addTransportObserver { [weak self] in self?.syncFromController() }
    }

    /// Reflect the controller's state, but only while THIS note is the loaded one. When the
    /// controller moves on to another note (or clears), this model reads as not playing.
    private func syncFromController() {
        isPlaying = controller.isLoaded(note) && controller.isPlaying
    }
}
