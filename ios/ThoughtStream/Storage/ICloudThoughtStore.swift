import Foundation

/// Persists thoughts as Markdown files in the app's iCloud Drive ubiquity container, under
/// `Documents/ThoughtStream/`, so thoughts sync across a user's devices and appear in the Files app.
///
/// Every read, write, and delete goes through `NSFileCoordinator` (coordinated IO) so this store
/// never races the iCloud sync daemon writing the same file. One thought is one `<id>.md` file, using
/// the same `Thought` Markdown serialization as the local `ThoughtStore`, so a file written by either
/// store is readable by either.
///
/// Thoughts can live in nested FOLDERS (spec 0010): a folder is a real subdirectory the Files app
/// surfaces, a thought in it lives at `directory/<folderPath>/<id>.md` with its `<id>.m4a` beside it.
/// `folderPath` is a thought's LOCATION, derived on load and consumed on save - never serialized into
/// the Markdown. EVERY tree walk, move (re-file), cascade delete, and directory create is wrapped in
/// `NSFileCoordinator` exactly as the file reads/writes/deletes are, so no folder operation
/// introduces an uncoordinated file op on the iCloud path.
///
/// This is the sibling of `ThoughtStore` selected by `ThoughtStoreFactory` when the ubiquity container
/// resolves. When iCloud is unavailable the factory picks `ThoughtStore` instead and this type is
/// never constructed.
struct ICloudThoughtStore: ThoughtStoring {
    /// The `ThoughtStream/` directory inside the container's `Documents`. This is where the thoughts
    /// live and what the Files app surfaces (the container Documents folder is user-visible).
    let directory: URL

    /// The coordinator used for all IO. A fresh coordinator per operation is fine and cheap.
    private let fileManager = FileManager.default

    /// Build a store rooted at `<containerDocuments>/ThoughtStream/`.
    ///
    /// - Parameter containerDocumentsURL: the ubiquity container's `Documents` directory, i.e.
    ///   `containerURL.appendingPathComponent("Documents")`.
    init(containerDocumentsURL: URL) {
        self.directory = containerDocumentsURL.appendingPathComponent("ThoughtStream", isDirectory: true)
    }

    /// Build a store rooted at an explicit thoughts directory. Private so callers cannot confuse it
    /// with `init(containerDocumentsURL:)` - both take a `URL` but mean different things (this one
    /// is the exact thoughts dir, that one is the container Documents that gets `ThoughtStream/`
    /// appended). Reach it through `forTesting(directory:)`.
    private init(directory: URL) {
        self.directory = directory
    }

    /// Build a store rooted at an explicit directory, for tests against a temp dir. The label
    /// makes the test-only, no-appending semantics unmistakable at the call site.
    static func forTesting(directory: URL) -> ICloudThoughtStore {
        ICloudThoughtStore(directory: directory)
    }

    /// The directory a folder path resolves to under the root, sanitizing every component so a name
    /// can never contain a separator and escape the tree.
    func directoryURL(for folderPath: [String]) -> URL {
        var url = directory
        for name in folderPath {
            let safe = Thought.sanitizedFolderName(name)
            guard !safe.isEmpty else { continue }
            url = url.appendingPathComponent(safe, isDirectory: true)
        }
        return url
    }

    /// The file URL for a top-level thought id (root of the tree).
    func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).md", isDirectory: false)
    }

    /// Ensure the thoughts directory exists, coordinating the creation so it does not race sync.
    /// Protected with `completeUnlessOpen` to match the local store.
    func ensureDirectory() throws {
        try ensureDirectory(at: directory)
    }

    /// Ensure an arbitrary directory in the tree exists, coordinated, with the same at-rest
    /// protection as the root. Used for folder creation and for placing a thought under its `folderPath`.
    private func ensureDirectory(at url: URL) throws {
        var coordinationError: NSError?
        var thrown: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError) { writeURL in
            do {
                if !fileManager.fileExists(atPath: writeURL.path) {
                    try fileManager.createDirectory(
                        at: writeURL,
                        withIntermediateDirectories: true,
                        attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
                    )
                }
            } catch {
                thrown = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
    }

    /// Locate an existing `<id>.md` anywhere in the tree, or nil when the thought has no file yet. The
    /// directory walk is coordinated so it does not race the sync daemon. Used by the id-only
    /// operations so they work regardless of the folder a thought sits in.
    func locateFile(id: UUID) -> URL? {
        let target = "\(id.uuidString).md"
        var found: URL?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: directory, options: [], error: &coordinationError) { dirURL in
            let rootURL = dirURL.appendingPathComponent(target, isDirectory: false)
            if fileManager.fileExists(atPath: rootURL.path) {
                found = rootURL
                return
            }
            guard let enumerator = fileManager.enumerator(
                at: dirURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return }
            for case let url as URL in enumerator where url.lastPathComponent == target {
                found = url
                break
            }
        }
        return found
    }

    /// Write the thought as Markdown under its `folderPath`, coordinated so the write does not collide
    /// with a concurrent sync of the same file. RELOCATES an existing `<id>.md` (and its `<id>.m4a`)
    /// when the thought's folder changed - the move IS the re-file and leaves nothing behind - with every
    /// step (locate walk, audio move, old-file delete, dir create, write) coordinated.
    @discardableResult
    func save(_ thought: Thought) throws -> URL {
        let destinationDir = directoryURL(for: thought.folderPath)
        try ensureDirectory(at: destinationDir)
        let destination = destinationDir.appendingPathComponent("\(thought.id.uuidString).md", isDirectory: false)

        // Capture where the thought's file lives NOW, before writing anything: a re-file is a move only
        // when an existing file sits in a different directory than the destination.
        let existing = locateFile(id: thought.id)
        let isMove = existing.map {
            $0.deletingLastPathComponent().standardizedFileURL != destination.deletingLastPathComponent().standardizedFileURL
        } ?? false

        // Write the new `.md` FIRST (coordinated), so the thought is never without a `.md`: a partial
        // failure below leaves the thought readable at its new home rather than stranded.
        let data = Data(thought.markdown.utf8)
        var coordinationError: NSError?
        var thrown: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: destination, options: [.forReplacing], error: &coordinationError) { writeURL in
            do {
                try data.write(to: writeURL, options: .atomic)
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUnlessOpen],
                    ofItemAtPath: writeURL.path
                )
            } catch {
                thrown = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }

        // Only after the new `.md` exists do we complete a move: relocate the sibling recording
        // (coordinated) then remove the old `.md` LAST (coordinated). A failure at any earlier point
        // never orphans audio or strands the thought with no `.md`.
        if isMove, let existing {
            let audioName = "\(thought.id.uuidString).\(Self.audioFileExtension)"
            let oldAudio = existing.deletingLastPathComponent().appendingPathComponent(audioName, isDirectory: false)
            let newAudio = destinationDir.appendingPathComponent(audioName, isDirectory: false)
            try coordinatedMoveIfExists(from: oldAudio, to: newAudio)
            try coordinatedDelete(at: existing)
        }
        return destination
    }

    /// Load every thought, newest first, walking the tree recursively (coordinated) and tagging each
    /// thought with the relative folder path of its file. Then reads each `.md` file (each coordinated).
    /// Unreadable files are skipped, not fatal - matching the local store's tolerance.
    func loadAll() -> [Thought] {
        var urls: [URL] = []
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: directory, options: [], error: &coordinationError) { dirURL in
            guard let enumerator = fileManager.enumerator(
                at: dirURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
                urls.append(url)
            }
        }
        if coordinationError != nil { return [] }

        var thoughts: [Thought] = []
        for url in urls {
            if let thought = readThought(at: url) {
                let folderPath = ThoughtStore.relativeFolderPath(of: url, under: directory)
                thoughts.append(thought.withFolderPath(folderPath))
            }
        }
        return thoughts.sorted { $0.createdAt > $1.createdAt }
    }

    /// Load a single thought by id from anywhere in the tree, or nil if missing or unreadable.
    func load(id: UUID) -> Thought? {
        guard let url = locateFile(id: id), let thought = readThought(at: url) else { return nil }
        let folderPath = ThoughtStore.relativeFolderPath(of: url, under: directory)
        return thought.withFolderPath(folderPath)
    }

    /// Delete a thought's file and its sibling audio recording, wherever in the tree they live.
    /// Coordinated. No-op for whichever does not exist.
    func delete(id: UUID) throws {
        if let url = locateFile(id: id) {
            let dir = url.deletingLastPathComponent()
            try coordinatedDelete(at: url)
            let audio = dir.appendingPathComponent("\(id.uuidString).\(Self.audioFileExtension)", isDirectory: false)
            try coordinatedDelete(at: audio)
        } else {
            // No `.md` located; still make sure no orphan recording lingers under the root.
            try deleteAudio(for: id)
        }
    }

    /// Coordinated delete of a single file or directory subtree. No-op if it does not exist.
    /// `removeItem` on a directory cascades to its whole subtree (used by `deleteFolder`).
    private func coordinatedDelete(at url: URL) throws {
        var coordinationError: NSError?
        var thrown: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: [.forDeleting], error: &coordinationError) { deleteURL in
            do {
                if fileManager.fileExists(atPath: deleteURL.path) {
                    try fileManager.removeItem(at: deleteURL)
                }
            } catch {
                thrown = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
    }

    /// Coordinated move of `source` to `destination` when `source` exists, overwriting any existing
    /// destination. Uses the paired writing-coordination for a move so neither end races the daemon.
    private func coordinatedMoveIfExists(from source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        var coordinationError: NSError?
        var thrown: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            writingItemAt: source, options: [.forMoving],
            writingItemAt: destination, options: [.forReplacing],
            error: &coordinationError
        ) { fromURL, toURL in
            do {
                if fileManager.fileExists(atPath: toURL.path) {
                    try fileManager.removeItem(at: toURL)
                }
                try fileManager.moveItem(at: fromURL, to: toURL)
            } catch {
                thrown = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
    }

    // MARK: - Recoverable delete (spec 0020)

    /// The store's trash root: a hidden `.trash/` directory INSIDE the store root, so soft-deleted files
    /// never leave the tree and are skipped by `loadAll` (which skips hidden files). Each deleted thought
    /// gets its own `<id>/` subdirectory holding its `<id>.md` (and `<id>.m4a`). Every move/delete here
    /// is coordinated through `NSFileCoordinator` exactly like the rest of this store.
    private var trashRoot: URL {
        directory.appendingPathComponent(Self.trashDirectoryName, isDirectory: true)
    }

    /// The trash subdirectory for one thought id: `.trash/<id>/`.
    private func trashDirectory(for id: UUID) -> URL {
        trashRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Resolve a folder path to a RESTORE destination at or below the store root, or nil when it
    /// escapes. Empty path resolves to the root itself (a top-level restore); anything collapsing/
    /// escaping above the root is rejected so a crafted former-folder path can never place a restored
    /// file outside the tree. Distinct from `resolvedFolderDirectory` (which rejects the root) because
    /// restoring a top-level thought legitimately targets the root.
    private func resolvedRestoreDirectory(for path: [String]) -> URL? {
        let dir = directoryURL(for: path).standardizedFileURL
        let root = directory.standardizedFileURL
        guard dir == root || dir.path.hasPrefix(root.path + "/") else { return nil }
        return dir
    }

    /// Soft-delete a thought: MOVE its `<id>.md` (and sibling `<id>.m4a` if present) into `.trash/<id>/`
    /// (coordinated), returning a `DeletedThought` token sufficient to `restore`. Returns nil when the thought
    /// has no `.md` to trash. The move only ever lands inside the store root.
    @discardableResult
    func softDelete(id: UUID) throws -> DeletedThought? {
        guard let thoughtURL = locateFile(id: id) else { return nil }
        let sourceDir = thoughtURL.deletingLastPathComponent()
        let folderPath = ThoughtStore.relativeFolderPath(of: thoughtURL, under: directory)

        let trashDir = trashDirectory(for: id)
        // Clear a stale trash subdir for this id (a re-delete after a crash mid-purge) so the move never
        // lands on an occupied destination.
        if coordinatedExists(at: trashDir) { try coordinatedDelete(at: trashDir) }
        try ensureDirectory(at: trashDir)

        let thoughtName = thoughtURL.lastPathComponent
        let trashedThought = trashDir.appendingPathComponent(thoughtName, isDirectory: false)
        try coordinatedMoveIfExists(from: thoughtURL, to: trashedThought)

        var audioName: String?
        let audioSibling = sourceDir.appendingPathComponent(
            "\(id.uuidString).\(Self.audioFileExtension)", isDirectory: false)
        if coordinatedExists(at: audioSibling) {
            let name = audioSibling.lastPathComponent
            do {
                try coordinatedMoveIfExists(from: audioSibling, to: trashDir.appendingPathComponent(name, isDirectory: false))
            } catch {
                // ROLL BACK the thought move so a failed audio move never leaves the thought half-in-trash with
                // no token (which would drop it from the list, give it no undo, and let the launch sweep
                // destroy it). Move the thought back so it ends up FULLY in place, then rethrow.
                try? coordinatedMoveIfExists(from: trashedThought, to: thoughtURL)
                throw error
            }
            audioName = name
        }

        return DeletedThought(
            id: id, formerFolderPath: folderPath, thoughtFilename: thoughtName, audioFilename: audioName)
    }

    /// Restore a soft-deleted thought: move its trashed `.md` (and `.m4a`) back to its former folder path
    /// (coordinated). If that folder no longer exists it lands at ROOT instead (never a failure). Removes
    /// the now-empty `.trash/<id>/` directory afterward.
    @discardableResult
    func restore(_ token: DeletedThought) throws -> RestoredThought {
        let trashDir = trashDirectory(for: token.id)

        let landedAtRoot: Bool
        let destinationDir: URL
        if !token.formerFolderPath.isEmpty,
           let resolved = resolvedRestoreDirectory(for: token.formerFolderPath),
           coordinatedExists(at: resolved) {
            destinationDir = resolved
            landedAtRoot = false
        } else {
            destinationDir = directory
            landedAtRoot = !token.formerFolderPath.isEmpty
        }
        try ensureDirectory(at: destinationDir)

        // The restored filenames are derived from the VALIDATED UUID (`<id>.md` / `<id>.m4a`), not the
        // token's stored filename, so the destination is structurally un-traversable regardless of the
        // token's contents - the same id-keyed naming `softDelete`/`purge` use.
        let thoughtDestName = "\(token.id.uuidString).md"
        let audioDestName = "\(token.id.uuidString).\(Self.audioFileExtension)"

        // Move the thought file back FIRST so a partial failure never strands audio without its thought.
        let trashedThought = trashDir.appendingPathComponent(token.thoughtFilename, isDirectory: false)
        try coordinatedMoveIfExists(
            from: trashedThought,
            to: destinationDir.appendingPathComponent(thoughtDestName, isDirectory: false))
        if let audioName = token.audioFilename {
            let trashedAudio = trashDir.appendingPathComponent(audioName, isDirectory: false)
            try coordinatedMoveIfExists(
                from: trashedAudio,
                to: destinationDir.appendingPathComponent(audioDestName, isDirectory: false))
        }

        if coordinatedExists(at: trashDir) { try? coordinatedDelete(at: trashDir) }

        let restoredPath = landedAtRoot ? [] : token.formerFolderPath
        return RestoredThought(id: token.id, folderPath: restoredPath, landedAtRoot: landedAtRoot)
    }

    /// Permanently remove a soft-deleted thought's trashed files (coordinated). No-op if already gone.
    func purge(_ token: DeletedThought) throws {
        try coordinatedDelete(at: trashDirectory(for: token.id))
    }

    /// Empty the whole trash directory (a launch-time sweep, coordinated). No-op when the trash is absent.
    func purgeAllTrash() throws {
        try coordinatedDelete(at: trashRoot)
    }

    // MARK: - Audio recording (spec 0007)

    /// The sibling audio URL for a thought id: `<id>.m4a` beside the thought's `<id>.md`, wherever it lives.
    /// Falls back to the root when the thought has no file yet (a fresh capture; the thought file is written
    /// first so the recording lands in the right folder - see DictationViewModel).
    func audioURL(for id: UUID) -> URL? {
        let dir = locateFile(id: id)?.deletingLastPathComponent() ?? directory
        return dir.appendingPathComponent("\(id.uuidString).\(Self.audioFileExtension)", isDirectory: false)
    }

    /// Move a freshly captured recording into the thought's audio slot, coordinated so the write does
    /// not collide with a concurrent sync, and protected to match the thought file.
    @discardableResult
    func saveAudio(from temporaryURL: URL, for id: UUID) throws -> URL {
        guard let destination = audioURL(for: id) else { return temporaryURL }
        try ensureDirectory(at: destination.deletingLastPathComponent())

        var coordinationError: NSError?
        var thrown: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: destination, options: [.forReplacing], error: &coordinationError) { writeURL in
            do {
                if fileManager.fileExists(atPath: writeURL.path) {
                    try fileManager.removeItem(at: writeURL)
                }
                try fileManager.moveItem(at: temporaryURL, to: writeURL)
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUnlessOpen],
                    ofItemAtPath: writeURL.path
                )
            } catch {
                thrown = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
        return destination
    }

    /// Atomically replace a thought's EXISTING recording with a rewritten one (spec 0019 dead-air trim),
    /// COORDINATED through `NSFileCoordinator` (`.forReplacing`) so the swap never races the sync
    /// daemon on the ubiquity-container file, and using `replaceItemAt` inside the coordination block
    /// so there is never a window where the thought has no recording. Re-asserts protection.
    ///
    /// It NEVER creates a recording: when the destination is absent (the thought was soft-deleted, moved,
    /// or never had audio) it DELETES the temp and returns nil, rather than materializing an orphan
    /// `.m4a` at the resolved slot that `loadAll`/`purgeAllTrash` would never see (defeating a delete).
    @discardableResult
    func replaceAudio(from temporaryURL: URL, for id: UUID) throws -> URL? {
        guard let destination = audioURL(for: id), coordinatedExists(at: destination) else {
            try? fileManager.removeItem(at: temporaryURL)
            return nil
        }

        var coordinationError: NSError?
        var thrown: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: destination, options: [.forReplacing], error: &coordinationError) { writeURL in
            do {
                _ = try fileManager.replaceItemAt(writeURL, withItemAt: temporaryURL)
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUnlessOpen],
                    ofItemAtPath: writeURL.path
                )
            } catch {
                thrown = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
        return destination
    }

    /// Delete a thought's audio recording, wherever in the tree it lives. Coordinated. No-op if missing.
    func deleteAudio(for id: UUID) throws {
        guard let url = audioURL(for: id) else { return }
        try coordinatedDelete(at: url)
    }

    /// Coordinated read of a single thought file, mapping its contents through `Thought`. Returns nil
    /// when the file is missing or unreadable so a partially-synced file never fails a load.
    private func readThought(at url: URL) -> Thought? {
        var thought: Thought?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            guard let text = try? String(contentsOf: readURL, encoding: .utf8) else { return }
            let fallbackID = UUID(uuidString: readURL.deletingPathExtension().lastPathComponent) ?? UUID()
            let modified = (try? readURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            thought = Thought(markdown: text, fallbackID: fallbackID, fallbackDate: modified)
        }
        return thought
    }

    /// Whether a recording exists for a thought id, coordinated so the check does not race the sync
    /// daemon. Does not force a download - it reports on the current local state of the container.
    func audioExists(for id: UUID) -> Bool {
        guard let url = audioURL(for: id) else { return false }
        var exists = false
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            exists = fileManager.fileExists(atPath: readURL.path)
        }
        return coordinationError == nil && exists
    }

    // MARK: - Folders (spec 0010)

    /// The child folder names directly under `path` (empty `path` = the top level), sorted A-Z. The
    /// directory read is coordinated so it does not race the sync daemon.
    func folders(at path: [String]) -> [String] {
        let dir = directoryURL(for: path)
        var names: [String] = []
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: dir, options: [], error: &coordinationError) { dirURL in
            guard let entries = try? fileManager.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            names = entries.compactMap { url -> String? in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return isDir ? url.lastPathComponent : nil
            }
        }
        if coordinationError != nil { return [] }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Create a folder named `name` under `path`, coordinated. Returns the sanitized name used (nil
    /// when it sanitizes to empty). Idempotent: creating an existing folder is a no-op.
    @discardableResult
    func createFolder(named name: String, at path: [String]) throws -> String? {
        let safe = Thought.sanitizedFolderName(name)
        guard !safe.isEmpty else { return nil }
        let dir = directoryURL(for: path).appendingPathComponent(safe, isDirectory: true)
        try ensureDirectory(at: dir)
        return safe
    }

    /// Resolve `path` to a folder directory that is STRICTLY BELOW the root, or nil when the path is
    /// empty, invalid, collapsing, or escaping. Same root-collapse guard as the local store: because
    /// rejected name components sanitize to `""` and are skipped in `directoryURL(for:)`, a path like
    /// `[".."]`, `["."]`, or `["/"]` would collapse to the ROOT, so a destructive op keyed off it
    /// could wipe or move the whole tree. Returning nil unless the resolved directory sits strictly
    /// under the root turns those into safe no-ops.
    private func resolvedFolderDirectory(for path: [String]) -> URL? {
        let dir = directoryURL(for: path).standardizedFileURL
        let root = directory.standardizedFileURL
        guard dir != root, dir.path.hasPrefix(root.path + "/") else { return nil }
        return dir
    }

    /// A coordinated existence check: reports whether an item exists at `url`, coordinating the read
    /// so it does not race the sync daemon. Keeps the "every op coordinated" invariant for the
    /// rename clobber guard, which must not read the destination through a bare FileManager call.
    private func coordinatedExists(at url: URL) -> Bool {
        var exists = false
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            exists = fileManager.fileExists(atPath: readURL.path)
        }
        return coordinationError == nil && exists
    }

    /// Rename the folder at `path` to `newName`, keeping everything inside it (the directory moves,
    /// coordinated). Returns the sanitized new name, or nil when it sanitizes to empty or is missing.
    @discardableResult
    func renameFolder(at path: [String], to newName: String) throws -> String? {
        guard let source = resolvedFolderDirectory(for: path) else { return nil }
        let safe = Thought.sanitizedFolderName(newName)
        guard !safe.isEmpty else { return nil }
        let destination = source.deletingLastPathComponent().appendingPathComponent(safe, isDirectory: true)
        guard source.standardizedFileURL != destination.standardizedFileURL else { return safe }
        guard coordinatedExists(at: source) else { return nil }
        // Allow a case-only rename (e.g. "work" -> "Work"): on the case-insensitive iOS volume the
        // source and destination are the SAME directory, so there is no other folder to clobber.
        let caseOnly = source.standardizedFileURL.path.lowercased() == destination.standardizedFileURL.path.lowercased()
        // Never clobber a DIFFERENT existing sibling folder: renaming onto a name already taken would
        // delete that folder and everything in it. Reject (via a COORDINATED existence check, so the
        // guard does not break the every-op-coordinated invariant) so the UI can report the conflict.
        if !caseOnly {
            guard !coordinatedExists(at: destination) else { return nil }
        }
        try coordinatedMoveIfExists(from: source, to: destination)
        return safe
    }

    /// Delete the folder at `path` and everything inside it (thoughts, recordings, subfolders) as a
    /// coordinated, recursive cascade. No-op if the folder does not exist or the path does not
    /// resolve strictly below the root (so an empty/invalid/collapsing path never deletes the tree).
    func deleteFolder(at path: [String]) throws {
        guard let dir = resolvedFolderDirectory(for: path) else { return }
        try coordinatedDelete(at: dir)
    }
}
