import Foundation

/// Deletes note recordings that have outlived the user's auto-delete window (spec 0007).
///
/// Runs once at launch. Only the audio sibling is removed; the note's text is always kept, so a
/// swept note simply loses its recording and falls back to text-to-speech on "read that back". This
/// is a no-op for the `keep` and `transcriptOnly` policies (nothing to expire).
///
/// Kept off the main actor: it reads the store (`loadAll` can block on coordinated iCloud IO) and
/// deletes through it, mirroring the discipline the note-list load already follows.
struct AudioRetentionSweeper {
    let store: NoteStoring

    /// Delete the recording of every note older than the retention window. Uses `now` and `createdAt`
    /// so the caller can inject a clock in tests. Deletion errors are swallowed per note so one
    /// stuck file does not stop the sweep. Returns the ids whose audio was deleted (for tests).
    @discardableResult
    func sweep(retention: AudioRetention, now: Date = Date()) -> [UUID] {
        guard let days = retention.autoDeleteDays else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)

        var deleted: [UUID] = []
        for note in store.loadAll() where note.hasAudio && note.createdAt < cutoff {
            do {
                try store.deleteAudio(for: note.id)
                deleted.append(note.id)
            } catch {
                // Best-effort: skip a file that will not delete rather than failing the whole sweep.
            }
        }
        return deleted
    }
}
