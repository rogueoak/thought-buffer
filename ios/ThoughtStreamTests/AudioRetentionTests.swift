import XCTest
@testable import ThoughtStream

/// Retention policy encoding and behavior (spec 0007), plus its persistence through the settings
/// store and the auto-delete sweep.
final class AudioRetentionTests: XCTestCase {

    // MARK: - Policy

    func testRecordsAudioByPolicy() {
        XCTAssertTrue(AudioRetention.keep.recordsAudio)
        XCTAssertTrue(AudioRetention.autoDeleteDays(30).recordsAudio)
        XCTAssertFalse(AudioRetention.transcriptOnly.recordsAudio)
    }

    func testStorageTagRoundTrip() {
        for retention: AudioRetention in [.keep, .transcriptOnly, .autoDeleteDays(7)] {
            XCTAssertEqual(AudioRetention(storageTag: retention.storageTag), retention)
        }
    }

    func testUnknownTagFallsBackToKeep() {
        XCTAssertEqual(AudioRetention(storageTag: "from-a-newer-build"), .keep)
        XCTAssertEqual(AudioRetention(storageTag: ""), .keep)
        XCTAssertEqual(AudioRetention(storageTag: "autoDelete:notanumber"), .keep)
    }

    func testAutoDeleteDaysClampToBounds() {
        // The tag clamps out-of-range windows; decoding a clamped tag yields the bounded value.
        let low = AudioRetention(storageTag: AudioRetention.autoDeleteDays(0).storageTag)
        XCTAssertEqual(low, .autoDeleteDays(AudioRetention.minDays))
        let high = AudioRetention(storageTag: AudioRetention.autoDeleteDays(99_999).storageTag)
        XCTAssertEqual(high, .autoDeleteDays(AudioRetention.maxDays))
    }

    // MARK: - Persistence

    func testSettingsStorePersistsRetention() {
        let suite = "AudioRetentionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UserDefaultsSettingsStore(defaults: defaults)
        // Default is keep.
        XCTAssertEqual(store.audioRetention, .keep)

        store.audioRetention = .transcriptOnly
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).audioRetention, .transcriptOnly)

        store.audioRetention = .autoDeleteDays(14)
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).audioRetention, .autoDeleteDays(14))
    }

    // MARK: - Sweep

    func testSweepDeletesAudioForNotesOlderThanWindow() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SweepTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NoteStore(directory: dir)

        let now = Date()
        // An old note (40 days) with audio, and a recent note (2 days) with audio.
        let old = try saveNoteWithAudio(store: store, createdAt: now.addingTimeInterval(-40 * 86_400))
        let recent = try saveNoteWithAudio(store: store, createdAt: now.addingTimeInterval(-2 * 86_400))

        let sweeper = AudioRetentionSweeper(store: store)
        let deleted = sweeper.sweep(retention: .autoDeleteDays(30), now: now)

        XCTAssertEqual(deleted, [old])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(for: old)!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: recent)!.path))
        // The note text is always kept, only its recording goes.
        XCTAssertNotNil(store.load(id: old))
    }

    func testSweepIsNoOpForKeep() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SweepKeep-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NoteStore(directory: dir)
        let id = try saveNoteWithAudio(store: store, createdAt: Date(timeIntervalSince1970: 0))

        let deleted = AudioRetentionSweeper(store: store).sweep(retention: .keep, now: Date())
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: id)!.path))
    }

    /// Save a note plus a stand-in audio sibling with the given creation date. Returns its id.
    private func saveNoteWithAudio(store: NoteStore, createdAt: Date) throws -> UUID {
        let id = UUID()
        let note = Note(
            id: id,
            title: "n",
            paragraphs: ["Body."],
            createdAt: createdAt,
            audioFileName: "\(id.uuidString).m4a",
            timings: [ParagraphTiming(start: 0, duration: 1)]
        )
        try store.save(note)
        // A stand-in recording file; the sweep only cares that the sibling exists and the note is old.
        let audioURL = store.audioURL(for: id)!
        try Data("fake-audio".utf8).write(to: audioURL)
        return id
    }
}
