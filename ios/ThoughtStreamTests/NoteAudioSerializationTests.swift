import XCTest
@testable import ThoughtStream

/// Note (de)serialization with and without audio / timings (spec 0007). Proves the recording fields
/// round-trip when present and that a note WITHOUT them serializes and parses exactly as before, so
/// files already on disk keep loading.
final class NoteAudioSerializationTests: XCTestCase {

    func testTextOnlyNoteHasNoAudioKeysAndRoundTrips() {
        let note = Note(
            title: "Plain note",
            paragraphs: ["No recording here.", "Just words."],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        // A text-only note never writes the audio/timings frontmatter, so old files are unchanged.
        XCTAssertFalse(note.markdown.contains("audio:"))
        XCTAssertFalse(note.markdown.contains("timings:"))

        let parsed = Note(markdown: note.markdown)
        XCTAssertFalse(parsed.hasAudio)
        XCTAssertNil(parsed.audioFileName)
        XCTAssertTrue(parsed.timings.isEmpty)
        XCTAssertEqual(parsed.paragraphs, note.paragraphs)
    }

    /// Backward-compat golden string: a text-only note serializes BYTE-FOR-BYTE as it always has,
    /// with no `audio:`/`timings:` keys. Pinned against the exact expected file so a change to the
    /// frontmatter (a reordered key, an always-written audio line) that would break files already on
    /// disk fails loudly here.
    func testTextOnlyNoteSerializesByteForByteAsBefore() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let note = Note(
            id: id,
            title: "Golden note",
            paragraphs: ["First line.", "Second line."],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let expected = """
        ---
        id: 11111111-2222-3333-4444-555555555555
        title: Golden note
        created: 2023-11-14T22:13:20.000Z
        ---

        First line.

        Second line.

        """
        XCTAssertEqual(note.markdown, expected)
    }

    func testNoteWithAudioRoundTrips() {
        let id = UUID()
        let note = Note(
            id: id,
            title: "Recorded note",
            paragraphs: ["First said.", "Second said."],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            audioFileName: "\(id.uuidString).m4a",
            timings: [
                ParagraphTiming(start: 0.0, duration: 2.5),
                ParagraphTiming(start: 2.5, duration: 3.0),
            ]
        )
        XCTAssertTrue(note.markdown.contains("audio: \(id.uuidString).m4a"))
        XCTAssertTrue(note.markdown.contains("timings:"))

        let parsed = Note(markdown: note.markdown)
        XCTAssertTrue(parsed.hasAudio)
        XCTAssertEqual(parsed.audioFileName, "\(id.uuidString).m4a")
        XCTAssertEqual(parsed.timings.count, 2)
        XCTAssertEqual(parsed.timing(forParagraphAt: 0)?.start, 0.0)
        XCTAssertEqual(parsed.timing(forParagraphAt: 1)?.start, 2.5)
        XCTAssertEqual(parsed.timing(forParagraphAt: 1)?.duration, 3.0)
    }

    func testAudioKeyWithoutTimingsIsTreatedAsTextOnly() {
        // A stray audio key with no timings is not a real recording; treat as text-only, not a crash.
        let text = """
        ---
        id: \(UUID().uuidString)
        title: Odd
        created: 2023-11-14T22:13:20.000Z
        audio: something.m4a
        ---

        Body.
        """
        let note = Note(markdown: text)
        XCTAssertFalse(note.hasAudio)
        XCTAssertNil(note.audioFileName)
    }

    func testMalformedTimingsDoNotFailTheParse() {
        let text = """
        ---
        id: \(UUID().uuidString)
        title: Broken timings
        created: 2023-11-14T22:13:20.000Z
        audio: rec.m4a
        timings: not-json-at-all
        ---

        Body still loads.
        """
        let note = Note(markdown: text)
        // Malformed timings degrade to text-only rather than throwing away the note.
        XCTAssertFalse(note.hasAudio)
        XCTAssertEqual(note.paragraphs, ["Body still loads."])
    }

    func testTimingEncodeDecodeRoundTrip() {
        let timings = [
            ParagraphTiming(start: 1.25, duration: 0.75),
            ParagraphTiming(start: 2.0, duration: 4.5),
        ]
        let encoded = Note.encodeTimings(timings)
        let decoded = Note.decodeTimings(encoded)
        XCTAssertEqual(decoded, timings)
    }

    func testTimingForParagraphOutOfRangeIsNil() {
        let note = Note(
            title: "x",
            paragraphs: ["One."],
            createdAt: Date(),
            audioFileName: "a.m4a",
            timings: [ParagraphTiming(start: 0, duration: 1)]
        )
        XCTAssertNotNil(note.timing(forParagraphAt: 0))
        XCTAssertNil(note.timing(forParagraphAt: 5))
    }
}
