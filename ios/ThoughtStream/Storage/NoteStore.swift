import Foundation

/// Persists notes as Markdown files under `Documents/ThoughtStream/`.
///
/// One note is one `<id>.md` file. Saving is atomic; loading is tolerant of files that are
/// missing frontmatter or partially written. The store is deliberately thin: no in-memory
/// cache, so the on-disk files are the single source of truth and later sync features can watch
/// the directory without fighting a cache.
struct NoteStore: NoteStoring {
    /// The directory that holds the note files. Defaults to the app's Documents directory,
    /// but tests can point it at a temporary directory.
    let directory: URL

    /// Create a store rooted at `Documents/ThoughtStream/`.
    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.directory = documents.appendingPathComponent("ThoughtStream", isDirectory: true)
    }

    /// Create a store rooted at an explicit directory (used by tests).
    init(directory: URL) {
        self.directory = directory
    }

    /// Ensure the notes directory exists, creating it if needed. The directory is protected with
    /// `completeUnlessOpen` so note contents stay encrypted at rest when the device is locked,
    /// while a file already open across a lock (a long dictation session) keeps working.
    func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
        )
    }

    /// The file URL for a given note id.
    func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).md", isDirectory: false)
    }

    /// Write the note to disk as Markdown, overwriting any existing file for its id.
    @discardableResult
    func save(_ note: Note) throws -> URL {
        try ensureDirectory()
        let url = fileURL(for: note.id)
        try note.markdown.write(to: url, atomically: true, encoding: .utf8)
        // Protect the note at rest: encrypted when the device is locked, but readable while the
        // file is already open (so a session that spans a lock is not cut off).
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: url.path
        )
        return url
    }

    /// Load every note from disk, newest first. Files that cannot be read are skipped rather
    /// than failing the whole load.
    func loadAll() -> [Note] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var notes: [Note] = []
        for url in entries where url.pathExtension.lowercased() == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let fallbackID = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            let note = Note(markdown: text, fallbackID: fallbackID, fallbackDate: modified)
            notes.append(note)
        }

        return notes.sorted { $0.createdAt > $1.createdAt }
    }

    /// Load a single note by id, or nil if it is missing or unreadable.
    func load(id: UUID) -> Note? {
        let url = fileURL(for: id)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Note(markdown: text, fallbackID: id, fallbackDate: Date())
    }

    /// Delete a note's file and its sibling audio recording. No-op for whichever does not exist.
    func delete(id: UUID) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        // Never leave an orphaned recording behind when the note goes.
        try deleteAudio(for: id)
    }

    // MARK: - Audio recording (spec 0007)

    /// The sibling audio URL for a note id: `<id>.m4a` next to `<id>.md`.
    func audioURL(for id: UUID) -> URL? {
        directory.appendingPathComponent("\(id.uuidString).\(Self.audioFileExtension)", isDirectory: false)
    }

    /// Move a freshly captured recording into the note's audio slot, overwriting any existing one.
    /// Protected with `completeUnlessOpen` to match the note file: raw audio is more sensitive than
    /// text, so it is encrypted at rest when the device is locked, while a file open across a lock
    /// (a long session) keeps working.
    @discardableResult
    func saveAudio(from temporaryURL: URL, for id: UUID) throws -> URL {
        try ensureDirectory()
        guard let destination = audioURL(for: id) else { return temporaryURL }
        let fm = FileManager.default
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

    /// Delete a note's audio recording. No-op if it does not exist.
    func deleteAudio(for id: UUID) throws {
        guard let url = audioURL(for: id) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
