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
    /// Whether `title` is a title the USER set, as opposed to one auto-derived from the first sentence
    /// (spec 0009). It governs edit-time behavior: a non-custom note re-derives its title when the body
    /// changes; a custom note keeps the user's title. Persisted as `titleCustom: true` in frontmatter,
    /// written ONLY when true so a derived-title note serializes byte-for-byte as before.
    let hasCustomTitle: Bool
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
        hasCustomTitle: Bool = false,
        audioFileName: String? = nil,
        timings: [ParagraphTiming] = []
    ) {
        self.id = id
        self.title = title
        self.paragraphs = paragraphs
        self.createdAt = createdAt
        self.hasCustomTitle = hasCustomTitle
        self.audioFileName = audioFileName
        self.timings = timings
    }

    /// The number of paragraphs in the note.
    var paragraphCount: Int { paragraphs.count }

    /// The total number of words across all paragraphs, counting runs of non-whitespace as words.
    /// Shown on the note card (feedback 0005) instead of a paragraph count, which read oddly ("1
    /// paragraphs") and told the user little.
    var wordCount: Int {
        paragraphs.reduce(0) { total, paragraph in
            total + paragraph
                .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                .count
        }
    }

    /// A short, correctly-pluralized word-count label ("1 word", "12 words") for the note card.
    var wordCountLabel: String {
        let count = wordCount
        return "\(count) " + (count == 1 ? "word" : "words")
    }

    /// The recording's length formatted as "m:ss" (or "h:mm:ss" past an hour), e.g. "1:24".
    var recordingDurationLabel: String {
        Note.durationLabel(recordingDuration)
    }

    /// The at-a-glance stat shown beside the timestamp on the card and detail header (feedback 0010):
    /// the recording duration for a note that has audio, falling back to the word count for a
    /// text-only note (transcript-only retention, resumed/edited notes, older files) so it is never
    /// blank. The caller chooses the icon (a duration reads better with a timer glyph than the word
    /// glyph), so both this and `hasAudio` are exposed.
    var metaStatLabel: String {
        hasAudio ? recordingDurationLabel : wordCountLabel
    }

    /// Format a duration in seconds as "m:ss" (or "h:mm:ss" past an hour). A negative or NaN duration
    /// clamps to "0:00" so a timing slip never renders garbage. Single source of truth for the app's
    /// duration formatting - the recordings browser (`RecordingsListModel`) delegates here.
    static func durationLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// A short preview drawn from the first paragraph.
    var snippet: String {
        paragraphs.first ?? ""
    }

    /// Whether this note carries a recording. Both an audio filename AND at least one timing are
    /// required, and this is an intentional dual-guard rather than an accident:
    ///
    /// - `DictationViewModel.attachRecording` GUARANTEES the pairing when it saves: it only sets
    ///   `audioFileName` after building one timing per paragraph, and it refuses to attach (deleting
    ///   the just-saved `.m4a` and saving text-only) unless at least one timing has a real, non-zero
    ///   duration. So a recording whose recognizer returned all-zero timings is never silently kept
    ///   as an unplayable file with no ranges - it is dropped cleanly, audio file and all.
    /// - On parse (`init(markdown:)`) both keys must be present for the same reason: a stray `audio:`
    ///   key with no `timings:` (or vice versa) is treated as a text-only note, so a half-written or
    ///   future-format file never surfaces a recording we cannot map to paragraphs.
    ///
    /// The storage sweep and playback both key off this, so they agree on exactly one definition of
    /// "has a recording" and a recording is never half-recognized.
    var hasAudio: Bool { audioFileName != nil && !timings.isEmpty }

    /// The timing of the paragraph at `index`, or nil when there is no recorded range for it.
    func timing(forParagraphAt index: Int) -> ParagraphTiming? {
        guard timings.indices.contains(index) else { return nil }
        return timings[index]
    }

    /// The recording's length in seconds: the tail of the last-ending paragraph range (the max of
    /// `start + duration` across timings). Zero when the note has no timings. Used to show the
    /// recording duration in the recordings browser and to feed `MPNowPlayingInfoCenter`'s total
    /// playback duration. Independent of paragraph ORDER (a timing math slip cannot make it negative),
    /// so it is a stable "how long is this recording" value.
    var recordingDuration: Double {
        timings.map { $0.start + $0.duration }.max() ?? 0
    }
}

// MARK: - Title derivation

extension Note {
    /// The longest sensible title we keep when deriving one from the first line.
    private static let titleCap = 60

    /// Derive a human title from the note's paragraphs, or a dated fallback when empty.
    /// The FIRST SENTENCE of the first non-empty paragraph wins (spec 0009: the natural title is
    /// what you said before your first pause, not the whole first line), trimmed and capped; a
    /// trailing period is dropped. A first paragraph with no terminal punctuation is one sentence,
    /// so it is used whole.
    static func deriveTitle(paragraphs: [String], createdAt: Date) -> String {
        let firstParagraph = paragraphs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })

        if let paragraph = firstParagraph, !paragraph.isEmpty {
            var title = SentenceTokenizer.sentences(in: paragraph).first ?? paragraph
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

    /// The `(title, isCustom)` a title-edit commit resolves to (spec 0009): a blank entry resets to
    /// the derived first sentence and clears the custom flag; anything else (trimmed) is a user title.
    /// Pure so the reset/set rule is unit-testable rather than trapped in the view's commit handler.
    static func resolveTitleEdit(
        rawTitle: String,
        paragraphs: [String],
        createdAt: Date
    ) -> (title: String, isCustom: Bool) {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return (deriveTitle(paragraphs: paragraphs, createdAt: createdAt), false)
        }
        return (trimmed, true)
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
        // Only mark a USER-set title, so a derived-title note serializes exactly as before (spec 0009).
        if hasCustomTitle {
            lines.append("titleCustom: true")
        }
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
        var hasCustomTitle = false
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
                case "titleCustom":
                    hasCustomTitle = (value == "true")
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
        // Prefer a stored title (every existing file keeps its title byte-for-byte); the custom flag
        // only counts when there IS a stored title to own. With no stored title, derive and stay
        // non-custom so a stray `titleCustom` key never marks a derived title as user-set.
        if let title {
            self.title = title
            self.hasCustomTitle = hasCustomTitle
        } else {
            self.title = Note.deriveTitle(paragraphs: paragraphs, createdAt: createdAt)
            self.hasCustomTitle = false
        }
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
