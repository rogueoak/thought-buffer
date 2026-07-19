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

    // MARK: - Recoverable delete (spec 0020)

    /// Soft-delete a note: MOVE its `<id>.md` (and sibling `<id>.m4a` if present) into the store's
    /// trash directory rather than removing them, returning a `DeletedNote` token sufficient to
    /// `restore(_:)` it. Returns nil when the note has no file to delete (nothing to trash). The move
    /// stays inside the store root, guarded like every other file op.
    @discardableResult
    func softDelete(id: UUID) throws -> DeletedNote?

    /// Restore a soft-deleted note: move its trashed files back to their former folder path. If that
    /// folder no longer exists the note lands at ROOT instead (never a failure); the returned
    /// `RestoredNote` records where it actually landed. No-op-safe if the trashed files are gone.
    @discardableResult
    func restore(_ token: DeletedNote) throws -> RestoredNote

    /// Permanently remove a soft-deleted note's trashed files (commit the delete). Called when the
    /// undo window closes and opportunistically on launch. No-op if the trashed files are already gone.
    func purge(_ token: DeletedNote) throws

    /// Permanently remove EVERY trashed note (a launch-time sweep for tokens with no pending undo).
    /// Empties the store's trash directory. No-op when the trash is empty or absent.
    func purgeAllTrash() throws

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

    // MARK: - Folders (spec 0010)

    /// The child folder names directly under `path` (empty `path` = the top level), sorted A-Z. A
    /// folder is a real subdirectory on disk. Returns `[]` for a store that keeps no folders.
    func folders(at path: [String]) -> [String]

    /// Create a folder named `name` under `path`, returning the sanitized name actually used, or nil
    /// when the name sanitizes to empty. Creating an existing folder is a no-op (idempotent).
    @discardableResult
    func createFolder(named name: String, at path: [String]) throws -> String?

    /// Rename the folder at `path` (its last component) to `newName`, keeping every note, recording,
    /// and subfolder inside it (they live in the directory, which is moved). Returns the sanitized new
    /// name, or nil when it sanitizes to empty.
    @discardableResult
    func renameFolder(at path: [String], to newName: String) throws -> String?

    /// Delete the folder at `path` and everything inside it - notes, their recordings, and subfolders
    /// (a recursive cascade). No-op if the folder does not exist.
    func deleteFolder(at path: [String]) throws
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

    /// The name of the per-store trash directory (spec 0020): a hidden subdirectory INSIDE the store
    /// root that holds soft-deleted files until they are restored or purged. Hidden (leading dot) so it
    /// never shows in the Files app or is walked by `loadAll` (which skips hidden files). One constant
    /// so both stores agree on the location.
    static var trashDirectoryName: String { ".trash" }

    // MARK: - Recoverable-delete defaults (spec 0020)

    /// Default: a store without an on-disk tree (an in-memory test stub) has nothing to soft-delete.
    /// The file-backed stores override this. It still hard-`delete`s so the stub stays consistent.
    @discardableResult
    func softDelete(id: UUID) throws -> DeletedNote? { try delete(id: id); return nil }

    /// Default no-op for stores without a trash directory. The file-backed stores override this.
    @discardableResult
    func restore(_ token: DeletedNote) throws -> RestoredNote {
        RestoredNote(id: token.id, folderPath: token.formerFolderPath, landedAtRoot: false)
    }

    /// Default no-op for stores without a trash directory. The file-backed stores override this.
    func purge(_ token: DeletedNote) throws {}

    /// Default no-op for stores without a trash directory. The file-backed stores override this.
    func purgeAllTrash() throws {}

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

    // MARK: - Folder defaults

    /// Default: a store without a real directory tree (an in-memory test stub) has no folders. The
    /// file-backed stores override this.
    func folders(at path: [String]) -> [String] { [] }

    /// Default no-op for stores without a directory tree. The file-backed stores override this.
    @discardableResult
    func createFolder(named name: String, at path: [String]) throws -> String? { nil }

    /// Default no-op for stores without a directory tree. The file-backed stores override this.
    @discardableResult
    func renameFolder(at path: [String], to newName: String) throws -> String? { nil }

    /// Default no-op for stores without a directory tree. The file-backed stores override this.
    func deleteFolder(at path: [String]) throws {}
}
