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

    func testSweepDeletesAudioForThoughtsOlderThanWindow() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SweepTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ThoughtStore(directory: dir)

        let now = Date()
        // An old thought (40 days) with audio, and a recent thought (2 days) with audio.
        let old = try saveThoughtWithAudio(store: store, createdAt: now.addingTimeInterval(-40 * 86_400))
        let recent = try saveThoughtWithAudio(store: store, createdAt: now.addingTimeInterval(-2 * 86_400))

        let sweeper = AudioRetentionSweeper(store: store)
        let deleted = await sweeper.sweep(retention: .autoDeleteDays(30), now: now)

        XCTAssertEqual(deleted, [old])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(for: old)!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: recent)!.path))
        // The thought text is always kept, only its recording goes.
        XCTAssertNotNil(store.load(id: old))
    }

    func testSweepIsNoOpForKeep() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SweepKeep-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ThoughtStore(directory: dir)
        let id = try saveThoughtWithAudio(store: store, createdAt: Date(timeIntervalSince1970: 0))

        let deleted = await AudioRetentionSweeper(store: store).sweep(retention: .keep, now: Date())
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: id)!.path))
    }

    /// A thought created exactly ON the cutoff boundary is NOT expired: the sweep keeps anything whose
    /// `createdAt` is not strictly older than the window (`createdAt < cutoff`). One second past the
    /// boundary IS swept, pinning the strict-inequality edge.
    func testSweepExpiryBoundaryIsExclusive() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SweepBoundary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ThoughtStore(directory: dir)

        // Use a whole-second epoch so the on-disk ISO-8601 round-trip is exact (no sub-millisecond
        // rounding that would make the boundary flaky).
        let window = 30
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cutoff = now.addingTimeInterval(-Double(window) * 86_400)
        // Exactly at the cutoff (kept: the check is strict `createdAt < cutoff`), and one second older
        // than the cutoff (swept).
        let atBoundary = try saveThoughtWithAudio(store: store, createdAt: cutoff)
        let justOlder = try saveThoughtWithAudio(store: store, createdAt: cutoff.addingTimeInterval(-1))

        let deleted = await AudioRetentionSweeper(store: store)
            .sweep(retention: .autoDeleteDays(window), now: now)

        XCTAssertEqual(deleted, [justOlder], "only the thought strictly older than the window is swept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: atBoundary)!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(for: justOlder)!.path))
    }

    /// Transcript-only never records, so there is nothing to expire: the sweep is a no-op even for an
    /// ancient thought that (by construction) has an audio sibling. Guards against a sweep keyed off the
    /// wrong policy silently deleting a kept recording.
    func testSweepIsNoOpForTranscriptOnly() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SweepTranscriptOnly-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ThoughtStore(directory: dir)
        let id = try saveThoughtWithAudio(store: store, createdAt: Date(timeIntervalSince1970: 0))

        let deleted = await AudioRetentionSweeper(store: store)
            .sweep(retention: .transcriptOnly, now: Date())
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: id)!.path))
    }

    /// Save a thought plus a stand-in audio sibling with the given creation date. Returns its id.
    private func saveThoughtWithAudio(store: ThoughtStore, createdAt: Date) throws -> UUID {
        let id = UUID()
        let thought = Thought(
            id: id,
            title: "n",
            paragraphs: ["Body."],
            createdAt: createdAt,
            audioFileName: "\(id.uuidString).m4a",
            timings: [ParagraphTiming(start: 0, duration: 1)]
        )
        try store.save(thought)
        // A stand-in recording file; the sweep only cares that the sibling exists and the thought is old.
        let audioURL = store.audioURL(for: id)!
        try Data("fake-audio".utf8).write(to: audioURL)
        return id
    }
}
