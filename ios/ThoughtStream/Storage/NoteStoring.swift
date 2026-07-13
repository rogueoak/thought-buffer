import Foundation

/// Persistence surface for notes, so views and view models depend on an abstraction rather than
/// the concrete `NoteStore`. The production implementation is `NoteStore`; tests can inject a
/// stub (for example, one that throws on save to exercise the error path).
protocol NoteStoring {
    /// Write the note to disk, overwriting any existing file for its id. Throws on failure.
    @discardableResult
    func save(_ note: Note) throws -> URL

    /// Load every note, newest first. Unreadable files are skipped, not fatal.
    func loadAll() -> [Note]

    /// Delete a note by id. No-op if it does not exist.
    func delete(id: UUID) throws
}
