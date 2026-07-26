import Foundation

/// Deletes thought recordings that have outlived the user's auto-delete window (spec 0007).
///
/// Runs once at launch. Only the audio sibling is removed; the thought's text is always kept, so a
/// swept thought simply loses its recording and falls back to text-to-speech on "read that back". This
/// is a no-op for the `keep` and `transcriptOnly` policies (nothing to expire).
///
/// Kept off the main actor: it reads the store (`loadAll` can block on coordinated iCloud IO) and
/// deletes through it, mirroring the discipline the thought-list load already follows.
struct AudioRetentionSweeper {
    let store: ThoughtStoring

    /// Delete the recording of every thought older than the retention window. Uses `now` and `createdAt`
    /// so the caller can inject a clock in tests. Deletion errors are swallowed per thought so one
    /// stuck file does not stop the sweep. Returns the ids whose audio was deleted (for tests).
    ///
    /// `async` on purpose: `store.loadAll()` / `deleteAudio` do coordinated IO that can block on the
    /// iCloud sync daemon, so this must run off the main actor. Marking it `async` (and awaiting it
    /// from a detached task, as the launch caller does) makes it impossible for a future caller to
    /// accidentally run this coordinated IO synchronously on the main actor.
    @discardableResult
    func sweep(retention: AudioRetention, now: Date = Date()) async -> [UUID] {
        guard let days = retention.autoDeleteDays else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)

        var deleted: [UUID] = []
        for thought in store.loadAll() where thought.hasAudio && thought.createdAt < cutoff {
            do {
                try store.deleteAudio(for: thought.id)
                deleted.append(thought.id)
            } catch {
                // Best-effort: skip a file that will not delete rather than failing the whole sweep.
            }
        }
        return deleted
    }
}
