import Foundation

/// A single captured note: a title plus an ordered list of paragraphs.
/// Presentational only for the themed shell; a real store replaces MockNotes later.
struct Note: Identifiable, Hashable {
    let id: UUID
    let title: String
    let paragraphs: [String]
    let createdAt: Date

    init(id: UUID = UUID(), title: String, paragraphs: [String], createdAt: Date) {
        self.id = id
        self.title = title
        self.paragraphs = paragraphs
        self.createdAt = createdAt
    }

    /// The number of paragraphs in the note.
    var paragraphCount: Int { paragraphs.count }

    /// A short preview drawn from the first paragraph.
    var snippet: String {
        paragraphs.first ?? ""
    }
}
