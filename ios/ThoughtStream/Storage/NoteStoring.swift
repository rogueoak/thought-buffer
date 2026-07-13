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

    /// Delete a note by id, including its sibling audio recording if present. No-op if it does not
    /// exist.
    func delete(id: UUID) throws

    // MARK: - Audio recording (spec 0007)

    /// The on-disk URL of the sibling audio recording for a note id (`<id>.m4a` next to `<id>.md`),
    /// or nil when this store does not keep audio on disk. The file may or may not exist; this is
    /// just where it lives.
    func audioURL(for id: UUID) -> URL?

    /// Adopt a recording that capture wrote to a temporary location, moving it to the note's
    /// sibling audio slot with the same coordination and protection as the note file. Overwrites any
    /// existing recording for the id. Returns the final URL. Throws on failure.
    @discardableResult
    func saveAudio(from temporaryURL: URL, for id: UUID) throws -> URL

    /// Delete a note's sibling audio recording. No-op if it does not exist. `delete(id:)` calls this
    /// too, so deleting a note never leaves an orphaned recording behind.
    func deleteAudio(for id: UUID) throws

    /// Whether a recording exists for a note id. On the iCloud backend this is coordinated so the
    /// answer is not raced against the sync daemon. Callers use it to decide whether to offer
    /// playback without reaching into the file system themselves.
    func audioExists(for id: UUID) -> Bool
}

extension NoteStoring {
    /// The on-disk format every note store writes. Both `NoteStore` and `ICloudNoteStore`
    /// serialize a `Note` to a `<id>.md` Markdown file, so this is a real invariant of the storage
    /// layer, not a stub. Exposed as one constant so the Settings "Format" row is driven from the
    /// truth rather than a duplicated literal that could silently drift.
    static var storageFormatLabel: String { "Markdown" }

    /// The file extension used for a note's sibling audio recording. AAC in an `.m4a` container:
    /// compressed so a long session stays small, and natively playable by `AVAudioPlayer`.
    static var audioFileExtension: String { "m4a" }

    // MARK: - Audio defaults

    /// Default: a store that does not keep audio on disk (an in-memory test stub) reports no URL.
    /// The file-backed stores override this.
    func audioURL(for id: UUID) -> URL? { nil }

    /// Default no-op for stores without on-disk audio. The file-backed stores override this.
    @discardableResult
    func saveAudio(from temporaryURL: URL, for id: UUID) throws -> URL { temporaryURL }

    /// Default no-op for stores without on-disk audio. The file-backed stores override this.
    func deleteAudio(for id: UUID) throws {}

    /// Default: a store with no on-disk audio never has a recording. The file-backed stores override
    /// this with a real (coordinated, on iCloud) existence check.
    func audioExists(for id: UUID) -> Bool { false }
}
