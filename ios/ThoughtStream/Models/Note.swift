import Foundation

/// A time range inside a note's recording, in seconds from the start of the recording. Attached
/// to a committed paragraph so playback can seek straight to it (see `AudioNotePlayer`).
struct ParagraphTiming: Hashable {
    /// Seconds from the start of the recording to where this paragraph begins.
    let start: Double
    /// The paragraph's length in seconds.
    let duration: Double

    init(start: Double, duration: Double) {
        self.start = start
        self.duration = duration
    }
}

/// A single captured note: a title plus an ordered list of paragraphs.
///
/// Notes persist as Markdown files (see `NoteStore`). The value type stays small and
/// extensible: later milestones (tags, source, edits, sync) can add fields and frontmatter
/// keys without breaking files already on disk, because parsing is tolerant of unknown keys.
///
/// A note MAY carry a recording of the voice that produced it (spec 0007): `audioFileName` names
/// the sibling `.m4a` next to the note's `.md`, and `timings` maps each paragraph to its range in
/// that recording. Both are optional and tolerant - a note with no audio (older files, or capture
/// with recording turned off) loads and behaves exactly as a text-only note always has.
struct Note: Identifiable, Hashable {
    let id: UUID
    let title: String
    let paragraphs: [String]
    let createdAt: Date
    /// The name of the sibling audio file (`<id>.m4a`), or nil when the note has no recording.
    let audioFileName: String?
    /// One timing per paragraph, in order, or empty when the note has no recording. When present
    /// but shorter than `paragraphs` (e.g. a paragraph edited in without audio), the extra
    /// paragraphs simply have no timing and fall back to text-to-speech on playback.
    let timings: [ParagraphTiming]

    init(
        id: UUID = UUID(),
        title: String,
        paragraphs: [String],
        createdAt: Date,
        audioFileName: String? = nil,
        timings: [ParagraphTiming] = []
    ) {
        self.id = id
        self.title = title
        self.paragraphs = paragraphs
        self.createdAt = createdAt
        self.audioFileName = audioFileName
        self.timings = timings
    }

    /// The number of paragraphs in the note.
    var paragraphCount: Int { paragraphs.count }

    /// A short preview drawn from the first paragraph.
    var snippet: String {
        paragraphs.first ?? ""
    }

    /// Whether this note carries a recording (a named audio file with at least one timing).
    var hasAudio: Bool { audioFileName != nil && !timings.isEmpty }

    /// The timing of the paragraph at `index`, or nil when there is no recorded range for it.
    func timing(forParagraphAt index: Int) -> ParagraphTiming? {
        guard timings.indices.contains(index) else { return nil }
        return timings[index]
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
    ///
    /// The `audio` and `timings` keys are written only when the note has a recording, so a
    /// text-only note serializes byte-for-byte as it always has. `timings` is a compact JSON array
    /// of `[start, duration]` pairs (seconds), one per paragraph; an old parser ignores both keys.
    var markdown: String {
        let created = Note.iso8601.string(from: createdAt)
        var lines = [
            "---",
            "id: \(id.uuidString)",
            "title: \(Note.escapeYAML(title))",
            "created: \(created)",
        ]
        if let audioFileName {
            lines.append("audio: \(Note.escapeYAML(audioFileName))")
        }
        if !timings.isEmpty {
            lines.append("timings: \(Note.encodeTimings(timings))")
        }
        lines.append("---")
        let front = lines.joined(separator: "\n")
        return front + "\n\n" + bodyMarkdown + "\n"
    }

    /// Encode timings as a compact JSON array of `[start, duration]` pairs. Kept on one frontmatter
    /// line so the format stays a single tolerant key.
    static func encodeTimings(_ timings: [ParagraphTiming]) -> String {
        let pairs = timings.map { [$0.start, $0.duration] }
        guard let data = try? JSONSerialization.data(withJSONObject: pairs, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// Decode timings from the compact JSON array written by `encodeTimings`. Tolerant: a malformed
    /// value yields an empty array (the note simply behaves as text-only) rather than failing the
    /// whole parse.
    static func decodeTimings(_ value: String) -> [ParagraphTiming] {
        guard let data = value.data(using: .utf8),
              let pairs = try? JSONSerialization.jsonObject(with: data) as? [[Double]] else {
            return []
        }
        return pairs.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return ParagraphTiming(start: pair[0], duration: pair[1])
        }
    }

    /// Parse a note from Markdown file contents. Tolerant: a file without frontmatter still
    /// loads as a body-only note. `fallbackDate` is used when no `created` key is present
    /// (typically the file's modification date).
    init(markdown text: String, fallbackID: UUID = UUID(), fallbackDate: Date = Date()) {
        var id = fallbackID
        var title: String?
        var createdAt = fallbackDate
        var audioFileName: String?
        var timings: [ParagraphTiming] = []
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
                case "audio":
                    let unescaped = Note.unescapeYAML(value)
                    if !unescaped.isEmpty { audioFileName = unescaped }
                case "timings":
                    timings = Note.decodeTimings(value)
                default:
                    break // unknown keys are ignored so future fields do not break old parsers
                }
            }
        }

        let paragraphs = Note.splitParagraphs(body)
        self.id = id
        self.paragraphs = paragraphs
        self.createdAt = createdAt
        // Only keep a recording reference when both halves are present; a stray key alone is not a
        // real recording, so treat it as a text-only note (backward compatible).
        if let audioFileName, !timings.isEmpty {
            self.audioFileName = audioFileName
            self.timings = timings
        } else {
            self.audioFileName = nil
            self.timings = []
        }
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
