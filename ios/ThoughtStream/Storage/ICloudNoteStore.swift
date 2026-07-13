import Foundation

/// Persists notes as Markdown files in the app's iCloud Drive ubiquity container, under
/// `Documents/ThoughtStream/`, so notes sync across a user's devices and appear in the Files app.
///
/// Every read, write, and delete goes through `NSFileCoordinator` (coordinated IO) so this store
/// never races the iCloud sync daemon writing the same file. One note is one `<id>.md` file, using
/// the same `Note` Markdown serialization as the local `NoteStore`, so a file written by either
/// store is readable by either.
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

    /// The file URL for a given note id.
    func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).md", isDirectory: false)
    }

    /// Ensure the notes directory exists, coordinating the creation so it does not race sync.
    /// Protected with `completeUnlessOpen` to match the local store.
    func ensureDirectory() throws {
        var coordinationError: NSError?
        var thrown: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: directory, options: [], error: &coordinationError) { url in
            do {
                if !fileManager.fileExists(atPath: url.path) {
                    try fileManager.createDirectory(
                        at: url,
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

    /// Write the note as Markdown, overwriting any existing file for its id. Coordinated so the
    /// write does not collide with a concurrent sync of the same file.
    @discardableResult
    func save(_ note: Note) throws -> URL {
        try ensureDirectory()
        let url = fileURL(for: note.id)
        let data = Data(note.markdown.utf8)

        var coordinationError: NSError?
        var thrown: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordinationError) { writeURL in
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
        return url
    }

    /// Load every note, newest first. Coordinates a read of the directory, then reads each `.md`
    /// file. Unreadable files are skipped, not fatal - matching the local store's tolerance.
    func loadAll() -> [Note] {
        var urls: [URL] = []
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: directory, options: [], error: &coordinationError) { dirURL in
            guard let entries = try? fileManager.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            urls = entries.filter { $0.pathExtension.lowercased() == "md" }
        }
        if coordinationError != nil { return [] }

        var notes: [Note] = []
        for url in urls {
            if let note = readNote(at: url) { notes.append(note) }
        }
        return notes.sorted { $0.createdAt > $1.createdAt }
    }

    /// Load a single note by id, or nil if missing or unreadable.
    func load(id: UUID) -> Note? {
        readNote(at: fileURL(for: id))
    }

    /// Delete a note's file. Coordinated. No-op if it does not exist.
    func delete(id: UUID) throws {
        let url = fileURL(for: id)
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
}
