import Foundation

/// Persists notes as Markdown files in the app's iCloud Drive ubiquity container, under
/// `Documents/ThoughtStream/`, so notes sync across a user's devices and appear in the Files app.
///
/// Every read, write, and delete goes through `NSFileCoordinator` (coordinated IO) so this store
/// never races the iCloud sync daemon writing the same file. One note is one `<id>.md` file, using
/// the same `Note` Markdown serialization as the local `NoteStore`, so a file written by either
/// store is readable by either.
///
/// Notes can live in nested FOLDERS (spec 0010): a folder is a real subdirectory the Files app
/// surfaces, a note in it lives at `directory/<folderPath>/<id>.md` with its `<id>.m4a` beside it.
/// `folderPath` is a note's LOCATION, derived on load and consumed on save - never serialized into
/// the Markdown. EVERY tree walk, move (re-file), cascade delete, and directory create is wrapped in
/// `NSFileCoordinator` exactly as the file reads/writes/deletes are, so no folder operation
/// introduces an uncoordinated file op on the iCloud path.
///
/// This is the sibling of `NoteStore` selected by `NoteStoreFactory` when the ubiquity container
/// resolves. When iCloud is unavailable the factory picks `NoteStore` instead and this type is
/// never constructed.
struct ICloudNoteStore: NoteStoring {
    /// The `ThoughtStream/` directory inside the container's `Documents`. This is where the notes
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

    /// Build a store rooted at an explicit notes directory. Private so callers cannot confuse it
    /// with `init(containerDocumentsURL:)` - both take a `URL` but mean different things (this one
    /// is the exact notes dir, that one is the container Documents that gets `ThoughtStream/`
    /// appended). Reach it through `forTesting(directory:)`.
    private init(directory: URL) {
        self.directory = directory
    }

    /// Build a store rooted at an explicit directory, for tests against a temp dir. The label
    /// makes the test-only, no-appending semantics unmistakable at the call site.
    static func forTesting(directory: URL) -> ICloudNoteStore {
        ICloudNoteStore(directory: directory)
    }

    /// The directory a folder path resolves to under the root, sanitizing every component so a name
    /// can never contain a separator and escape the tree.
    func directoryURL(for folderPath: [String]) -> URL {
        var url = directory
        for name in folderPath {
            let safe = Note.sanitizedFolderName(name)
            guard !safe.isEmpty else { continue }
            url = url.appendingPathComponent(safe, isDirectory: true)
        }
        return url
    }

    /// The file URL for a top-level note id (root of the tree).
    func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).md", isDirectory: false)
    }

    /// Ensure the notes directory exists, coordinating the creation so it does not race sync.
    /// Protected with `completeUnlessOpen` to match the local store.
    func ensureDirectory() throws {
        try ensureDirectory(at: directory)
    }

    /// Ensure an arbitrary directory in the tree exists, coordinated, with the same at-rest
    /// protection as the root. Used for folder creation and for placing a note under its `folderPath`.
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

    /// Locate an existing `<id>.md` anywhere in the tree, or nil when the note has no file yet. The
    /// directory walk is coordinated so it does not race the sync daemon. Used by the id-only
    /// operations so they work regardless of the folder a note sits in.
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

    /// Write the note as Markdown under its `folderPath`, coordinated so the write does not collide
    /// with a concurrent sync of the same file. RELOCATES an existing `<id>.md` (and its `<id>.m4a`)
    /// when the note's folder changed - the move IS the re-file and leaves nothing behind - with every
    /// step (locate walk, audio move, old-file delete, dir create, write) coordinated.
    @discardableResult
    func save(_ note: Note) throws -> URL {
        let destinationDir = directoryURL(for: note.folderPath)
        try ensureDirectory(at: destinationDir)
        let destination = destinationDir.appendingPathComponent("\(note.id.uuidString).md", isDirectory: false)

        // A note being re-filed: if its file lives in a different directory, this save is a move -
        // relocate the sibling recording (coordinated) and remove the old `.md` (coordinated).
        if let existing = locateFile(id: note.id),
           existing.deletingLastPathComponent().standardizedFileURL != destination.deletingLastPathComponent().standardizedFileURL {
            let audioName = "\(note.id.uuidString).\(Self.audioFileExtension)"
            let oldAudio = existing.deletingLastPathComponent().appendingPathComponent(audioName, isDirectory: false)
            let newAudio = destinationDir.appendingPathComponent(audioName, isDirectory: false)
            try coordinatedMoveIfExists(from: oldAudio, to: newAudio)
            try coordinatedDelete(at: existing)
        }

        let data = Data(note.markdown.utf8)
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
        return destination
    }

    /// Load every note, newest first, walking the tree recursively (coordinated) and tagging each
    /// note with the relative folder path of its file. Then reads each `.md` file (each coordinated).
    /// Unreadable files are skipped, not fatal - matching the local store's tolerance.
    func loadAll() -> [Note] {
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

        var notes: [Note] = []
        for url in urls {
            if let note = readNote(at: url) {
                let folderPath = NoteStore.relativeFolderPath(of: url, under: directory)
                notes.append(note.withFolderPath(folderPath))
            }
        }
        return notes.sorted { $0.createdAt > $1.createdAt }
    }

    /// Load a single note by id from anywhere in the tree, or nil if missing or unreadable.
    func load(id: UUID) -> Note? {
        guard let url = locateFile(id: id), let note = readNote(at: url) else { return nil }
        let folderPath = NoteStore.relativeFolderPath(of: url, under: directory)
        return note.withFolderPath(folderPath)
    }

    /// Delete a note's file and its sibling audio recording, wherever in the tree they live.
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

    // MARK: - Audio recording (spec 0007)

    /// The sibling audio URL for a note id: `<id>.m4a` beside the note's `<id>.md`, wherever it lives.
    /// Falls back to the root when the note has no file yet (a fresh capture; the note file is written
    /// first so the recording lands in the right folder - see DictationViewModel).
    func audioURL(for id: UUID) -> URL? {
        let dir = locateFile(id: id)?.deletingLastPathComponent() ?? directory
        return dir.appendingPathComponent("\(id.uuidString).\(Self.audioFileExtension)", isDirectory: false)
    }

    /// Move a freshly captured recording into the note's audio slot, coordinated so the write does
    /// not collide with a concurrent sync, and protected to match the note file.
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

    /// Delete a note's audio recording, wherever in the tree it lives. Coordinated. No-op if missing.
    func deleteAudio(for id: UUID) throws {
        guard let url = audioURL(for: id) else { return }
        try coordinatedDelete(at: url)
    }

    /// Coordinated read of a single note file, mapping its contents through `Note`. Returns nil
    /// when the file is missing or unreadable so a partially-synced file never fails a load.
    private func readNote(at url: URL) -> Note? {
        var note: Note?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            guard let text = try? String(contentsOf: readURL, encoding: .utf8) else { return }
            let fallbackID = UUID(uuidString: readURL.deletingPathExtension().lastPathComponent) ?? UUID()
            let modified = (try? readURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            note = Note(markdown: text, fallbackID: fallbackID, fallbackDate: modified)
        }
        return note
    }

    /// Whether a recording exists for a note id, coordinated so the check does not race the sync
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
        let safe = Note.sanitizedFolderName(name)
        guard !safe.isEmpty else { return nil }
        let dir = directoryURL(for: path).appendingPathComponent(safe, isDirectory: true)
        try ensureDirectory(at: dir)
        return safe
    }

    /// Rename the folder at `path` to `newName`, keeping everything inside it (the directory moves,
    /// coordinated). Returns the sanitized new name, or nil when it sanitizes to empty or is missing.
    @discardableResult
    func renameFolder(at path: [String], to newName: String) throws -> String? {
        guard !path.isEmpty else { return nil }
        let safe = Note.sanitizedFolderName(newName)
        guard !safe.isEmpty else { return nil }
        let source = directoryURL(for: path)
        let destination = source.deletingLastPathComponent().appendingPathComponent(safe, isDirectory: true)
        guard source.standardizedFileURL != destination.standardizedFileURL else { return safe }
        guard fileManager.fileExists(atPath: source.path) else { return nil }
        // Never clobber an existing sibling folder: renaming onto a name that already exists would
        // delete that folder and everything in it. Reject instead so the UI can report the conflict.
        guard !fileManager.fileExists(atPath: destination.path) else { return nil }
        try coordinatedMoveIfExists(from: source, to: destination)
        return safe
    }

    /// Delete the folder at `path` and everything inside it (notes, recordings, subfolders) as a
    /// coordinated, recursive cascade. No-op if the folder does not exist.
    func deleteFolder(at path: [String]) throws {
        guard !path.isEmpty else { return }
        try coordinatedDelete(at: directoryURL(for: path))
    }
}
