import Foundation

/// Persistence surface for thoughts, so views and view models depend on an abstraction rather than
/// the concrete `ThoughtStore`. The production implementation is `ThoughtStore`; tests can inject a
/// stub (for example, one that throws on save to exercise the error path).
///
/// `Sendable` because the store is loaded off the main actor (see `ThoughtStoreDriver.reload()`,
/// which captures it in a `Task.detached`); conformers must be safe to read concurrently. The
/// concrete stores are immutable value types over the file system (`ThoughtStore`, `ICloudThoughtStore`),
/// which is inherently safe.
protocol ThoughtStoring: Sendable {
    /// Write the thought to disk, overwriting any existing file for its id. Throws on failure.
    @discardableResult
    func save(_ thought: Thought) throws -> URL

    /// Load every thought, newest first. Unreadable files are skipped, not fatal.
    func loadAll() -> [Thought]

    /// Delete a thought by id, including its sibling audio recording if present. No-op if it does not
    /// exist.
    func delete(id: UUID) throws

    // MARK: - Recoverable delete (spec 0020)

    /// Soft-delete a thought: MOVE its `<id>.md` (and sibling `<id>.m4a` if present) into the store's
    /// trash directory rather than removing them, returning a `DeletedThought` token sufficient to
    /// `restore(_:)` it. Returns nil when the thought has no file to delete (nothing to trash). The move
    /// stays inside the store root, guarded like every other file op.
    @discardableResult
    func softDelete(id: UUID) throws -> DeletedThought?

    /// Restore a soft-deleted thought: move its trashed files back to their former folder path. If that
    /// folder no longer exists the thought lands at ROOT instead (never a failure); the returned
    /// `RestoredThought` records where it actually landed. No-op-safe if the trashed files are gone.
    @discardableResult
    func restore(_ token: DeletedThought) throws -> RestoredThought

    /// Permanently remove a soft-deleted thought's trashed files (commit the delete). Called when the
    /// undo window closes and opportunistically on launch. No-op if the trashed files are already gone.
    func purge(_ token: DeletedThought) throws

    /// Permanently remove EVERY trashed thought (a launch-time sweep for tokens with no pending undo).
    /// Empties the store's trash directory. No-op when the trash is empty or absent.
    func purgeAllTrash() throws

    // MARK: - Audio recording (spec 0007)

    /// The on-disk URL of the sibling audio recording for a thought id (`<id>.m4a` next to `<id>.md`),
    /// or nil when this store does not keep audio on disk. The file may or may not exist; this is
    /// just where it lives.
    func audioURL(for id: UUID) -> URL?

    /// Adopt a recording that capture wrote to a temporary location, moving it to the thought's
    /// sibling audio slot with the same coordination and protection as the thought file. Overwrites any
    /// existing recording for the id. Returns the final URL. Throws on failure.
    @discardableResult
    func saveAudio(from temporaryURL: URL, for id: UUID) throws -> URL

    /// Atomically REPLACE a thought's EXISTING recording with a rewritten one from `temporaryURL`
    /// (feedback 0022 resume-audio concatenation), coordinated (on iCloud) so the swap never races the
    /// sync daemon and protected to match the thought file. Distinct from `saveAudio`: it ONLY swaps in a
    /// processed version of an already-adopted recording, done as an ATOMIC replace so there is never a
    /// window where the thought has no recording.
    ///
    /// It NEVER creates a new recording. When no recording exists at the thought's slot - the thought was
    /// soft-deleted (its `.md` is hidden in trash, so the slot resolves to a non-existent root file),
    /// moved, or never had audio - it does NOT materialize a file (which would be an orphan raw-voice
    /// `.m4a`, invisible to `loadAll` and never purged, defeating the delete). Instead it DELETES the
    /// caller's temp file and returns nil ("nothing to replace"). On success returns the final URL.
    /// Throws on failure, leaving the original in place. Returns nil for a store that keeps no audio.
    @discardableResult
    func replaceAudio(from temporaryURL: URL, for id: UUID) throws -> URL?

    /// Delete a thought's sibling audio recording. No-op if it does not exist. `delete(id:)` calls this
    /// too, so deleting a thought never leaves an orphaned recording behind.
    func deleteAudio(for id: UUID) throws

    /// Whether a recording exists for a thought id. On the iCloud backend this is coordinated so the
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

    /// Rename the folder at `path` (its last component) to `newName`, keeping every thought, recording,
    /// and subfolder inside it (they live in the directory, which is moved). Returns the sanitized new
    /// name, or nil when it sanitizes to empty.
    @discardableResult
    func renameFolder(at path: [String], to newName: String) throws -> String?

    /// Delete the folder at `path` and everything inside it - thoughts, their recordings, and subfolders
    /// (a recursive cascade). No-op if the folder does not exist.
    func deleteFolder(at path: [String]) throws
}

extension ThoughtStoring {
    /// The on-disk format every thought store writes. Both `ThoughtStore` and `ICloudThoughtStore`
    /// serialize a `Thought` to a `<id>.md` Markdown file, so this is a real invariant of the storage
    /// layer, not a stub. Exposed as one constant so the Settings "Format" row is driven from the
    /// truth rather than a duplicated literal that could silently drift.
    static var storageFormatLabel: String { "Markdown" }

    /// The file extension used for a thought's sibling audio recording. AAC in an `.m4a` container:
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
    func softDelete(id: UUID) throws -> DeletedThought? { try delete(id: id); return nil }

    /// Default no-op for stores without a trash directory. The file-backed stores override this.
    @discardableResult
    func restore(_ token: DeletedThought) throws -> RestoredThought {
        RestoredThought(id: token.id, folderPath: token.formerFolderPath, landedAtRoot: false)
    }

    /// Default no-op for stores without a trash directory. The file-backed stores override this.
    func purge(_ token: DeletedThought) throws {}

    /// Default no-op for stores without a trash directory. The file-backed stores override this.
    func purgeAllTrash() throws {}

    // MARK: - Audio defaults

    /// Default: a store that does not keep audio on disk (an in-memory test stub) reports no URL.
    /// The file-backed stores override this.
    func audioURL(for id: UUID) -> URL? { nil }

    /// Default no-op for stores without on-disk audio. The file-backed stores override this.
    @discardableResult
    func saveAudio(from temporaryURL: URL, for id: UUID) throws -> URL { temporaryURL }

    /// Default for stores without on-disk audio: nothing to replace, and no orphan is left behind.
    /// The file-backed stores override this.
    @discardableResult
    func replaceAudio(from temporaryURL: URL, for id: UUID) throws -> URL? {
        try? FileManager.default.removeItem(at: temporaryURL)
        return nil
    }

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
