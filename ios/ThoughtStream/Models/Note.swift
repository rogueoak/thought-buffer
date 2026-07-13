import Foundation

/// A single captured note: a title plus an ordered list of paragraphs.
///
/// Notes persist as Markdown files (see `NoteStore`). The value type stays small and
/// extensible: later milestones (tags, source, edits, sync) can add fields and frontmatter
/// keys without breaking files already on disk, because parsing is tolerant of unknown keys.
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

// MARK: - Title derivation

extension Note {
    /// The longest sensible title we keep when deriving one from the first line.
    private static let titleCap = 60

    /// Derive a human title from the note's paragraphs, or a dated fallback when empty.
    /// The first non-empty line wins, trimmed and capped; a trailing period is dropped.
    static func deriveTitle(paragraphs: [String], createdAt: Date) -> String {
        let firstLine = paragraphs
            .flatMap { $0.split(separator: "\n", omittingEmptySubsequences: true) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })

        if let line = firstLine, !line.isEmpty {
            var title = line
            if title.count > titleCap {
                title = String(title.prefix(titleCap)).trimmingCharacters(in: .whitespaces) + "..."
            }
            if title.hasSuffix(".") {
                title = String(title.dropLast())
            }
            return title
        }
        return "Note " + Note.fallbackDateFormatter.string(from: createdAt)
    }

    private static let fallbackDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

// MARK: - Markdown serialization

extension Note {
    /// ISO-8601 with fractional seconds, used for the `created` frontmatter key.
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// The Markdown body: paragraphs joined by a blank line, empty paragraphs dropped.
    var bodyMarkdown: String {
        paragraphs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// The full Markdown file contents: YAML frontmatter followed by the body.
    var markdown: String {
        let created = Note.iso8601.string(from: createdAt)
        let front = """
        ---
        id: \(id.uuidString)
        title: \(Note.escapeYAML(title))
        created: \(created)
        ---
        """
        return front + "\n\n" + bodyMarkdown + "\n"
    }

    /// Parse a note from Markdown file contents. Tolerant: a file without frontmatter still
    /// loads as a body-only note. `fallbackDate` is used when no `created` key is present
    /// (typically the file's modification date).
    init(markdown text: String, fallbackID: UUID = UUID(), fallbackDate: Date = Date()) {
        var id = fallbackID
        var title: String?
        var createdAt = fallbackDate
        var body = text

        if let front = Note.extractFrontmatter(text) {
            body = front.body
            for (key, value) in front.fields {
                switch key {
                case "id":
                    if let parsed = UUID(uuidString: value) { id = parsed }
                case "title":
                    let unescaped = Note.unescapeYAML(value)
                    if !unescaped.isEmpty { title = unescaped }
                case "created":
                    if let parsed = Note.iso8601.date(from: value) { createdAt = parsed }
                default:
                    break // unknown keys are ignored so future fields do not break old parsers
                }
            }
        }

        let paragraphs = Note.splitParagraphs(body)
        self.id = id
        self.paragraphs = paragraphs
        self.createdAt = createdAt
        self.title = title ?? Note.deriveTitle(paragraphs: paragraphs, createdAt: createdAt)
    }

    /// Split a Markdown body into paragraphs on blank lines, trimming and dropping empties.
    static func splitParagraphs(_ body: String) -> [String] {
        body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: Frontmatter helpers

    private struct Frontmatter {
        let fields: [(String, String)]
        let body: String
    }

    private static func extractFrontmatter(_ text: String) -> Frontmatter? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return nil }
        let afterOpen = normalized.dropFirst(4)
        guard let closeRange = afterOpen.range(of: "\n---") else { return nil }

        let block = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])
        var rest = String(afterOpen[closeRange.upperBound...])
        if rest.hasPrefix("\n") { rest.removeFirst() }
        rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)

        var fields: [(String, String)] = []
        for line in block.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { fields.append((key, value)) }
        }
        return Frontmatter(fields: fields, body: rest)
    }

    /// Quote a YAML scalar when it contains characters that would confuse a naive parser.
    private static func escapeYAML(_ value: String) -> String {
        let needsQuoting = value.contains(":") || value.contains("#")
            || value.hasPrefix(" ") || value.hasSuffix(" ")
            || value.hasPrefix("\"") || value.isEmpty
        guard needsQuoting else { return value }
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    private static func unescapeYAML(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        let inner = value.dropFirst().dropLast()
        return inner.replacingOccurrences(of: "\\\"", with: "\"")
    }
}
