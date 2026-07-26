import Foundation

/// Persists thoughts as Markdown files under `Documents/ThoughtBuffer/`.
///
/// One thought is one `<id>.md` file. Saving is atomic; loading is tolerant of files that are
/// missing frontmatter or partially written. The store is deliberately thin: no in-memory
/// cache, so the on-disk files are the single source of truth and later sync features can watch
/// the directory without fighting a cache.
///
/// Thoughts can live in nested FOLDERS (spec 0010): a folder is a real subdirectory, a thought in it lives
/// at `directory/<folderPath>/<id>.md` with its `<id>.m4a` beside it. `folderPath` is a thought's
/// LOCATION, derived on load and consumed on save - never serialized into the Markdown, so a foldered
/// thought's `.md` is byte-identical to a top-level thought's. Id-only operations (`delete`, `audioURL`,
/// `saveAudio`, `deleteAudio`, `audioExists`) find a thought's file by scanning the tree, so the
/// `ThoughtStoring` audio surface stays id-only and nothing downstream (the resolver, playback) changes.
struct ThoughtStore: ThoughtStoring {
    /// The directory that holds the thought files. Defaults to the app's Documents directory,
    /// but tests can point it at a temporary directory.
    let directory: URL

    /// Create a store rooted at `Documents/ThoughtBuffer/`.
    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.directory = documents.appendingPathComponent("ThoughtBuffer", isDirectory: true)
    }

    /// Create a store rooted at an explicit directory (used by tests).
    init(directory: URL) {
        self.directory = directory
    }

    /// Ensure the thoughts directory exists, creating it if needed. The directory is protected with
    /// `completeUnlessOpen` so thought contents stay encrypted at rest when the device is locked,
    /// while a file already open across a lock (a long dictation session) keeps working.
    func ensureDirectory() throws {
        try ensureDirectory(at: directory)
    }

    /// Ensure an arbitrary directory in the tree exists, with the same at-rest protection as the root.
    private func ensureDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
        )
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

    /// The file URL for a top-level thought id (root of the tree). Kept for compatibility; a thought in a
    /// folder is placed by `save(_:)`/`locateFile(id:)` under its `folderPath`.
    func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).md", isDirectory: false)
    }

    /// Locate an existing `<id>.md` anywhere in the tree, or nil when the thought has no file yet. Used
    /// by the id-only operations (delete/audio) so they work regardless of the folder a thought sits in.
    func locateFile(id: UUID) -> URL? {
        let target = "\(id.uuidString).md"
        let fm = FileManager.default
        // Fast path: most thoughts are at the root, so check there before walking the whole tree.
        let rootURL = directory.appendingPathComponent(target, isDirectory: false)
        if fm.fileExists(atPath: rootURL.path) { return rootURL }

        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == target {
            return url
        }
        return nil
    }

    /// Write the thought to disk as Markdown under its `folderPath`, creating intermediate directories,
    /// and RELOCATE an existing `<id>.md` (and its `<id>.m4a`) when the thought's folder changed - so
    /// saving a thought with a new `folderPath` IS the move, and it leaves nothing behind.
    @discardableResult
    func save(_ thought: Thought) throws -> URL {
        let fm = FileManager.default
        let destinationDir = directoryURL(for: thought.folderPath)
        try ensureDirectory(at: destinationDir)
        let destination = destinationDir.appendingPathComponent("\(thought.id.uuidString).md", isDirectory: false)

        // Capture where the thought's file lives NOW, before writing anything: a re-file is a move only
        // when an existing file sits in a different directory than the destination.
        let existing = locateFile(id: thought.id)
        let isMove = existing.map {
            $0.deletingLastPathComponent().standardizedFileURL != destination.deletingLastPathComponent().standardizedFileURL
        } ?? false

        // Write the new `.md` to the destination FIRST, so the thought is never without a `.md`: a
        // partial failure below leaves the thought readable at its new home rather than stranded.
        try thought.markdown.write(to: destination, atomically: true, encoding: .utf8)
        // Protect the thought at rest: encrypted when the device is locked, but readable while the
        // file is already open (so a session that spans a lock is not cut off).
        try fm.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: destination.path
        )

        // Only after the new `.md` exists do we complete a move: relocate the sibling recording from
        // the old directory to the new one, then remove the old `.md` LAST. A failure at any earlier
        // point never orphans audio or strands the thought with no `.md`.
        if isMove, let existing {
            let existingDir = existing.deletingLastPathComponent()
            let audioName = "\(thought.id.uuidString).\(Self.audioFileExtension)"
            let oldAudio = existingDir.appendingPathComponent(audioName, isDirectory: false)
            if fm.fileExists(atPath: oldAudio.path) {
                let newAudio = destinationDir.appendingPathComponent(audioName, isDirectory: false)
                if fm.fileExists(atPath: newAudio.path) { try fm.removeItem(at: newAudio) }
                try fm.moveItem(at: oldAudio, to: newAudio)
            }
            try fm.removeItem(at: existing)
        }
        return destination
    }

    /// Load every thought from disk, newest first, walking the tree recursively and tagging each thought
    /// with the relative folder path of its file. Files that cannot be read are skipped rather than
    /// failing the whole load.
    func loadAll() -> [Thought] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var thoughts: [Thought] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let fallbackID = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            let folderPath = Self.relativeFolderPath(of: url, under: directory)
            let thought = Thought(markdown: text, fallbackID: fallbackID, fallbackDate: modified)
                .withFolderPath(folderPath)
            thoughts.append(thought)
        }

        return thoughts.sorted { $0.createdAt > $1.createdAt }
    }

    /// The ordered folder names between `root` and the file at `url` (empty for a file directly in
    /// `root`). Purely path arithmetic over the standardized URLs.
    static func relativeFolderPath(of url: URL, under root: URL) -> [String] {
        let rootComponents = root.standardizedFileURL.pathComponents
        let fileComponents = url.standardizedFileURL.deletingLastPathComponent().pathComponents
        guard fileComponents.count > rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
            return []
        }
        return Array(fileComponents.dropFirst(rootComponents.count))
    }

    /// Load a single thought by id from anywhere in the tree, or nil if it is missing or unreadable.
    func load(id: UUID) -> Thought? {
        guard let url = locateFile(id: id),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let folderPath = Self.relativeFolderPath(of: url, under: directory)
        return Thought(markdown: text, fallbackID: id, fallbackDate: Date()).withFolderPath(folderPath)
    }

    /// Delete a thought's file and its sibling audio recording, wherever in the tree they live. No-op
    /// for whichever does not exist.
    func delete(id: UUID) throws {
        if let url = locateFile(id: id) {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.removeItem(at: url)
            // Remove the sibling recording that sits beside the located thought file.
            let audio = dir.appendingPathComponent("\(id.uuidString).\(Self.audioFileExtension)", isDirectory: false)
            if FileManager.default.fileExists(atPath: audio.path) {
                try FileManager.default.removeItem(at: audio)
            }
        } else {
            // No `.md` located; still make sure no orphan recording lingers under the root.
            try deleteAudio(for: id)
        }
    }

    // MARK: - Recoverable delete (spec 0020)

    /// The store's trash root: a hidden `.trash/` directory INSIDE the store root, so soft-deleted files
    /// never leave the tree and are skipped by `loadAll` (which skips hidden files). Each deleted thought
    /// gets its own `<id>/` subdirectory under it, holding its `<id>.md` (and `<id>.m4a`).
    private var trashRoot: URL {
        directory.appendingPathComponent(Self.trashDirectoryName, isDirectory: true)
    }

    /// The trash subdirectory for one thought id: `.trash/<id>/`. Kept per-thought so restore/purge operate on
    /// exactly this thought's files and a whole-trash sweep is a single directory removal.
    private func trashDirectory(for id: UUID) -> URL {
        trashRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Resolve a folder path to a destination directory for RESTORE that is at or below the store root,
    /// or nil when it escapes. Empty path resolves to the root itself (a top-level restore); anything
    /// that would collapse/escape above the root is rejected so a crafted former-folder path can never
    /// place a restored file outside the tree. Distinct from `resolvedFolderDirectory` (which rejects the
    /// root) because restoring a top-level thought legitimately targets the root.
    private func resolvedRestoreDirectory(for path: [String]) -> URL? {
        let dir = directoryURL(for: path).standardizedFileURL
        let root = directory.standardizedFileURL
        guard dir == root || dir.path.hasPrefix(root.path + "/") else { return nil }
        return dir
    }

    /// Soft-delete a thought: MOVE its `<id>.md` (and sibling `<id>.m4a` if present) into `.trash/<id>/`,
    /// returning a `DeletedThought` token that records its former folder path and filenames so `restore`
    /// can put it back. Returns nil when the thought has no `.md` file to trash. The move only ever lands
    /// inside the store root (the trash is a subdirectory of it).
    @discardableResult
    func softDelete(id: UUID) throws -> DeletedThought? {
        let fm = FileManager.default
        guard let thoughtURL = locateFile(id: id) else { return nil }
        let sourceDir = thoughtURL.deletingLastPathComponent()
        let folderPath = Self.relativeFolderPath(of: thoughtURL, under: directory)

        let trashDir = trashDirectory(for: id)
        // A stale trash subdir for this id (a re-delete after a crash mid-purge) is cleared first so the
        // move never fails on an occupied destination.
        if fm.fileExists(atPath: trashDir.path) { try fm.removeItem(at: trashDir) }
        try ensureDirectory(at: trashDir)

        let thoughtName = thoughtURL.lastPathComponent
        let trashedThought = trashDir.appendingPathComponent(thoughtName, isDirectory: false)
        try fm.moveItem(at: thoughtURL, to: trashedThought)

        var audioName: String?
        let audioSibling = sourceDir.appendingPathComponent(
            "\(id.uuidString).\(Self.audioFileExtension)", isDirectory: false)
        if fm.fileExists(atPath: audioSibling.path) {
            let name = audioSibling.lastPathComponent
            do {
                try fm.moveItem(at: audioSibling, to: trashDir.appendingPathComponent(name, isDirectory: false))
            } catch {
                // ROLL BACK the thought move so a failed audio move never leaves the thought half-in-trash
                // with no token: without this, the thought would vanish from the list (no `.md` in the
                // tree), have no undo (no token returned), and be destroyed by the launch sweep. Undo the
                // thought move so the thought ends up FULLY in place, then rethrow - the caller surfaces the
                // failure and the thought stays listed. The trash subdir is left (empty) for the next try.
                try? fm.moveItem(at: trashedThought, to: thoughtURL)
                throw error
            }
            audioName = name
        }

        return DeletedThought(
            id: id, formerFolderPath: folderPath, thoughtFilename: thoughtName, audioFilename: audioName)
    }

    /// Restore a soft-deleted thought: move its trashed `.md` (and `.m4a`) back into its former folder path.
    /// If that folder no longer exists it lands at ROOT instead (never a failure). Removes the now-empty
    /// `.trash/<id>/` directory afterward.
    @discardableResult
    func restore(_ token: DeletedThought) throws -> RestoredThought {
        let fm = FileManager.default
        let trashDir = trashDirectory(for: token.id)

        // Choose the destination: the former folder if it still exists, else the root. `directoryURL` is
        // only trusted after `resolvedRestoreDirectory` confirms it stays within the tree.
        let landedAtRoot: Bool
        let destinationDir: URL
        if !token.formerFolderPath.isEmpty,
           let resolved = resolvedRestoreDirectory(for: token.formerFolderPath),
           fm.fileExists(atPath: resolved.path) {
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
        if fm.fileExists(atPath: trashedThought.path) {
            let destination = destinationDir.appendingPathComponent(thoughtDestName, isDirectory: false)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: trashedThought, to: destination)
        }
        if let audioName = token.audioFilename {
            let trashedAudio = trashDir.appendingPathComponent(audioName, isDirectory: false)
            if fm.fileExists(atPath: trashedAudio.path) {
                let destination = destinationDir.appendingPathComponent(audioDestName, isDirectory: false)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: trashedAudio, to: destination)
            }
        }

        if fm.fileExists(atPath: trashDir.path) { try? fm.removeItem(at: trashDir) }

        let restoredPath = landedAtRoot ? [] : token.formerFolderPath
        return RestoredThought(id: token.id, folderPath: restoredPath, landedAtRoot: landedAtRoot)
    }

    /// Permanently remove a soft-deleted thought's trashed files (commit the delete). No-op if already gone.
    func purge(_ token: DeletedThought) throws {
        let trashDir = trashDirectory(for: token.id)
        if FileManager.default.fileExists(atPath: trashDir.path) {
            try FileManager.default.removeItem(at: trashDir)
        }
    }

    /// Empty the whole trash directory (a launch-time sweep of tokens with no pending undo). No-op when
    /// the trash is absent.
    func purgeAllTrash() throws {
        if FileManager.default.fileExists(atPath: trashRoot.path) {
            try FileManager.default.removeItem(at: trashRoot)
        }
    }

    // MARK: - Audio recording (spec 0007)

    /// The sibling audio URL for a thought id: `<id>.m4a` beside the thought's `<id>.md`, wherever the thought
    /// lives in the tree. Falls back to the root when the thought has no file yet (a fresh capture, whose
    /// thought file is written first so the recording lands in the right folder - see DictationViewModel).
    func audioURL(for id: UUID) -> URL? {
        let dir = locateFile(id: id)?.deletingLastPathComponent() ?? directory
        return dir.appendingPathComponent("\(id.uuidString).\(Self.audioFileExtension)", isDirectory: false)
    }

    /// Move a freshly captured recording into the thought's audio slot, overwriting any existing one.
    /// Protected with `completeUnlessOpen` to match the thought file: raw audio is more sensitive than
    /// text, so it is encrypted at rest when the device is locked, while a file open across a lock
    /// (a long session) keeps working.
    @discardableResult
    func saveAudio(from temporaryURL: URL, for id: UUID) throws -> URL {
        guard let destination = audioURL(for: id) else { return temporaryURL }
        let fm = FileManager.default
        // The destination directory already exists when a thought file is present; ensure it otherwise
        // (a root-level fallback), so the move never fails on a missing parent.
        try ensureDirectory(at: destination.deletingLastPathComponent())
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: temporaryURL, to: destination)
        try fm.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: destination.path
        )
        return destination
    }

    /// Atomically replace a thought's EXISTING recording with a rewritten one (feedback 0022 resume-audio
    /// concatenation). Uses `replaceItemAt` so there is never a window where the thought has no recording;
    /// on any failure the original is left in place (`replaceItemAt` is atomic). Re-asserts audio file
    /// protection.
    ///
    /// It NEVER creates a recording: when the destination is absent (the thought was soft-deleted, moved,
    /// or never had audio) it DELETES the temp and returns nil, rather than materializing an orphan
    /// `.m4a` at the resolved slot that `loadAll`/`purgeAllTrash` would never see (defeating a delete).
    @discardableResult
    func replaceAudio(from temporaryURL: URL, for id: UUID) throws -> URL? {
        let fm = FileManager.default
        guard let destination = audioURL(for: id), fm.fileExists(atPath: destination.path) else {
            try? fm.removeItem(at: temporaryURL)
            return nil
        }
        _ = try fm.replaceItemAt(destination, withItemAt: temporaryURL)
        try fm.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: destination.path
        )
        return destination
    }

    /// Delete a thought's audio recording, wherever in the tree it lives. No-op if it does not exist.
    func deleteAudio(for id: UUID) throws {
        guard let url = audioURL(for: id) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Whether a recording exists for a thought id. A plain existence check for the local store.
    func audioExists(for id: UUID) -> Bool {
        guard let url = audioURL(for: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Folders (spec 0010)

    /// The child folder names directly under `path` (empty `path` = the top level), sorted A-Z.
    func folders(at path: [String]) -> [String] {
        let fm = FileManager.default
        let dir = directoryURL(for: path)
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let names = entries.compactMap { url -> String? in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return isDir ? url.lastPathComponent : nil
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Create a folder named `name` under `path`, returning the sanitized name used (nil when it
    /// sanitizes to empty). Idempotent: creating an existing folder is a no-op.
    @discardableResult
    func createFolder(named name: String, at path: [String]) throws -> String? {
        let safe = Thought.sanitizedFolderName(name)
        guard !safe.isEmpty else { return nil }
        let dir = directoryURL(for: path).appendingPathComponent(safe, isDirectory: true)
        try ensureDirectory(at: dir)
        return safe
    }

    /// Resolve `path` to a folder directory that is STRICTLY BELOW the root, or nil when the path is
    /// empty, invalid, collapsing, or escaping. This is the guard that keeps a destructive folder op
    /// from ever operating on the whole tree: because rejected name components sanitize to `""` and
    /// are skipped in `directoryURL(for:)`, a path like `[".."]`, `["."]`, or `["/"]` would collapse
    /// to the ROOT - so a delete/rename keyed off it could wipe or move everything. Returning nil
    /// unless the resolved directory sits strictly under the root turns those into safe no-ops.
    private func resolvedFolderDirectory(for path: [String]) -> URL? {
        let dir = directoryURL(for: path).standardizedFileURL
        let root = directory.standardizedFileURL
        guard dir != root, dir.path.hasPrefix(root.path + "/") else { return nil }
        return dir
    }

    /// Rename the folder at `path` to `newName`, keeping everything inside it (the directory moves).
    @discardableResult
    func renameFolder(at path: [String], to newName: String) throws -> String? {
        guard let source = resolvedFolderDirectory(for: path) else { return nil }
        let safe = Thought.sanitizedFolderName(newName)
        guard !safe.isEmpty else { return nil }
        let destination = source.deletingLastPathComponent().appendingPathComponent(safe, isDirectory: true)
        guard source.standardizedFileURL != destination.standardizedFileURL else { return safe }
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return nil }
        // Allow a case-only rename (e.g. "work" -> "Work"): on the case-insensitive iOS volume the
        // source and destination are the SAME directory, so there is no other folder to clobber.
        let caseOnly = source.standardizedFileURL.path.lowercased() == destination.standardizedFileURL.path.lowercased()
        // Never clobber a DIFFERENT existing sibling folder: renaming onto a name already taken would
        // delete that folder and everything in it. Reject instead so the UI can report the conflict.
        if !caseOnly {
            guard !fm.fileExists(atPath: destination.path) else { return nil }
        }
        try fm.moveItem(at: source, to: destination)
        return safe
    }

    /// Delete the folder at `path` and everything inside it (thoughts, recordings, subfolders). No-op if
    /// the folder does not exist or the path does not resolve strictly below the root (so an
    /// empty/invalid/collapsing path never deletes the whole tree). `removeItem` on the directory
    /// cascades to its whole subtree.
    func deleteFolder(at path: [String]) throws {
        guard let dir = resolvedFolderDirectory(for: path) else { return }
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}
