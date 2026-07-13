import Foundation

/// Persistence surface for notes, so views and view models depend on an abstraction rather than
/// the concrete `NoteStore`. The production implementation is `NoteStore`; tests can inject a
/// stub (for example, one that throws on save to exercise the error path).
///
/// `Sendable` because the store is loaded off the main actor (see `NoteStoreDriver.reload()`,
/// which captures it in a `Task.detached`); conformers must be safe to read concurrently. The
/// concrete stores are immutable value types over the file system (`NoteStore`, `ICloudNoteStore`),
/// which is inherently safe.
protocol NoteStoring: Sendable {
    /// Write the note to disk, overwriting any existing file for its id. Throws on failure.
    @discardableResult
    func save(_ note: Note) throws -> URL

    /// Load every note, newest first. Unreadable files are skipped, not fatal.
    func loadAll() -> [Note]

    /// Delete a note by id. No-op if it does not exist.
    func delete(id: UUID) throws
}
