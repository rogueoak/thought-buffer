import XCTest
@testable import ThoughtStream

/// Thought (de)serialization with and without audio / timings (spec 0007). Proves the recording fields
/// round-trip when present and that a thought WITHOUT them serializes and parses exactly as before, so
/// files already on disk keep loading.
final class ThoughtAudioSerializationTests: XCTestCase {

    /// A file written BEFORE the "note" -> "thought" rename (spec 0024) must still load byte-for-byte.
    /// The on-disk serialization is FROZEN: renaming the `Note` type to `Thought` never touched the
    /// frontmatter key strings (`id`, `title`, `titleCustom`, `created`, `audio`, `timings`), the
    /// `<id>.md`/`<id>.m4a` filename scheme, or the body structure, so every existing saved thought
    /// keeps loading. This pins an existing on-disk file (all keys present, an audio recording) and
    /// asserts it parses and plays exactly as it was saved.
    func testLegacyOnDiskFileWithAllFrozenKeysStillLoads() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let onDisk = """
        ---
        id: \(id.uuidString)
        title: Morning drive - thoughts
        titleCustom: true
        created: 2023-11-14T22:13:20.000Z
        audio: \(id.uuidString).m4a
        timings: [[0,2.5],[2.5,3]]
        ---

        First said.

        Second said.
        """
        let parsed = Thought(markdown: onDisk)
        XCTAssertEqual(parsed.id, id)
        XCTAssertEqual(parsed.title, "Morning drive - thoughts")
        XCTAssertTrue(parsed.hasCustomTitle)
        XCTAssertEqual(parsed.paragraphs, ["First said.", "Second said."])
        XCTAssertTrue(parsed.hasAudio)
        XCTAssertEqual(parsed.audioFileName, "\(id.uuidString).m4a")
        XCTAssertEqual(parsed.timings.count, 2)
        XCTAssertEqual(parsed.timing(forParagraphAt: 0)?.start, 0.0)
        XCTAssertEqual(parsed.timing(forParagraphAt: 0)?.duration, 2.5)
        XCTAssertEqual(parsed.timing(forParagraphAt: 1)?.start, 2.5)
        XCTAssertEqual(parsed.timing(forParagraphAt: 1)?.duration, 3.0)
        // Re-serializing writes the same frozen keys, so the round-trip is stable on disk.
        let reparsed = Thought(markdown: parsed.markdown)
        XCTAssertEqual(reparsed.title, parsed.title)
        XCTAssertEqual(reparsed.audioFileName, parsed.audioFileName)
        XCTAssertEqual(reparsed.timings, parsed.timings)
    }

    func testTextOnlyThoughtHasNoAudioKeysAndRoundTrips() {
        let thought = Thought(
            title: "Plain thought",
            paragraphs: ["No recording here.", "Just words."],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        // A text-only thought never writes the audio/timings frontmatter, so old files are unchanged.
        XCTAssertFalse(thought.markdown.contains("audio:"))
        XCTAssertFalse(thought.markdown.contains("timings:"))

        let parsed = Thought(markdown: thought.markdown)
        XCTAssertFalse(parsed.hasAudio)
        XCTAssertNil(parsed.audioFileName)
        XCTAssertTrue(parsed.timings.isEmpty)
        XCTAssertEqual(parsed.paragraphs, thought.paragraphs)
    }

    /// Backward-compat golden string: a text-only thought serializes BYTE-FOR-BYTE as it always has,
    /// with no `audio:`/`timings:` keys. Pinned against the exact expected file so a change to the
    /// frontmatter (a reordered key, an always-written audio line) that would break files already on
    /// disk fails loudly here.
    func testTextOnlyThoughtSerializesByteForByteAsBefore() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let thought = Thought(
            id: id,
            title: "Golden thought",
            paragraphs: ["First line.", "Second line."],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let expected = """
        ---
        id: 11111111-2222-3333-4444-555555555555
        title: Golden thought
        created: 2023-11-14T22:13:20.000Z
        ---

        First line.

        Second line.

        """
        XCTAssertEqual(thought.markdown, expected)
    }

    func testThoughtWithAudioRoundTrips() {
        let id = UUID()
        let thought = Thought(
            id: id,
            title: "Recorded thought",
            paragraphs: ["First said.", "Second said."],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            audioFileName: "\(id.uuidString).m4a",
            timings: [
                ParagraphTiming(start: 0.0, duration: 2.5),
                ParagraphTiming(start: 2.5, duration: 3.0),
            ]
        )
        XCTAssertTrue(thought.markdown.contains("audio: \(id.uuidString).m4a"))
        XCTAssertTrue(thought.markdown.contains("timings:"))

        let parsed = Thought(markdown: thought.markdown)
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
        let thought = Thought(markdown: text)
        XCTAssertFalse(thought.hasAudio)
        XCTAssertNil(thought.audioFileName)
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
        let thought = Thought(markdown: text)
        // Malformed timings degrade to text-only rather than throwing away the thought.
        XCTAssertFalse(thought.hasAudio)
        XCTAssertEqual(thought.paragraphs, ["Body still loads."])
    }

    func testTimingEncodeDecodeRoundTrip() {
        let timings = [
            ParagraphTiming(start: 1.25, duration: 0.75),
            ParagraphTiming(start: 2.0, duration: 4.5),
        ]
        let encoded = Thought.encodeTimings(timings)
        let decoded = Thought.decodeTimings(encoded)
        XCTAssertEqual(decoded, timings)
    }

    func testTimingForParagraphOutOfRangeIsNil() {
        let thought = Thought(
            title: "x",
            paragraphs: ["One."],
            createdAt: Date(),
            audioFileName: "a.m4a",
            timings: [ParagraphTiming(start: 0, duration: 1)]
        )
        XCTAssertNotNil(thought.timing(forParagraphAt: 0))
        XCTAssertNil(thought.timing(forParagraphAt: 5))
    }

    // MARK: - Duration + meta stat (feedback 0010)

    func testDurationLabelFormatsMinutesSecondsAndHours() {
        XCTAssertEqual(Thought.durationLabel(0), "0:00")
        XCTAssertEqual(Thought.durationLabel(9), "0:09")
        XCTAssertEqual(Thought.durationLabel(84), "1:24")
        XCTAssertEqual(Thought.durationLabel(3_723), "1:02:03")
        // A negative or NaN duration clamps to "0:00" rather than rendering garbage.
        XCTAssertEqual(Thought.durationLabel(-5), "0:00")
        XCTAssertEqual(Thought.durationLabel(.nan), "0:00")
    }

    func testMetaStatLabelIsRecordingDurationWhenThoughtHasAudio() {
        let id = UUID()
        let thought = Thought(
            title: "Recorded",
            paragraphs: ["One two three four five."],
            createdAt: Date(),
            audioFileName: "\(id.uuidString).m4a",
            timings: [ParagraphTiming(start: 0, duration: 84)]
        )
        XCTAssertTrue(thought.hasAudio)
        XCTAssertEqual(thought.recordingDurationLabel, "1:24")
        // With audio, the at-a-glance stat is the duration, not the word count.
        XCTAssertEqual(thought.metaStatLabel, "1:24")
    }

    func testMetaStatLabelFallsBackToWordCountWhenNoRecording() {
        let thought = Thought(
            title: "Text only",
            paragraphs: ["One two three four five."],
            createdAt: Date()
        )
        XCTAssertFalse(thought.hasAudio)
        // No recording -> the stat falls back to the word count so it is never blank.
        XCTAssertEqual(thought.metaStatLabel, thought.wordCountLabel)
        XCTAssertEqual(thought.metaStatLabel, "5 words")
    }
}
