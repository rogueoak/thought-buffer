import XCTest
@testable import ThoughtStream

/// Dual-capture behavior in the view model (spec 0007): the tee is enabled per the retention flag,
/// finalized segments carry a range that maps to paragraphs, saving adopts the recording plus
/// timings, and "read that back" plays the correct range with a text-to-speech fallback.
@MainActor
final class DualCaptureViewModelTests: XCTestCase {
    private var tempDir: URL!
    private var store: NoteStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DualCaptureVM-\(UUID().uuidString)", isDirectory: true)
        store = NoteStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Tee enable / disable

    func testRecordingEnabledWhenRetentionKeeps() {
        let service = RecordingStubCaptureService()
        _ = DictationViewModel(service: service, store: store, recordsAudio: true)
        XCTAssertTrue(service.recordingEnabled, "the tee must be armed when audio is kept")
    }

    func testRecordingDisabledForTranscriptOnly() {
        let service = RecordingStubCaptureService()
        _ = DictationViewModel(service: service, store: store, recordsAudio: false)
        XCTAssertFalse(service.recordingEnabled, "transcript-only must not arm the tee")
    }

    // MARK: - Paragraph <-> time mapping

    func testFinalizedSegmentsMapToParagraphTimings() throws {
        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        let model = DictationViewModel(service: service, store: store, recordsAudio: true)

        // Two segments; the second lands after a simulated recognizer restart, so its start is an
        // absolute recording offset, not zero. The view model must keep them 1:1 with paragraphs.
        service.emitFinalized("First paragraph.", range: ParagraphTiming(start: 0.0, duration: 2.0))
        service.emitFinalized("Second paragraph.", range: ParagraphTiming(start: 2.0, duration: 3.5))

        let note = try XCTUnwrap(try model.finish())
        XCTAssertEqual(note.paragraphs, ["First paragraph.", "Second paragraph."])
        XCTAssertTrue(note.hasAudio)
        XCTAssertEqual(note.timings.count, 2)
        XCTAssertEqual(note.timing(forParagraphAt: 0)?.start, 0.0)
        XCTAssertEqual(note.timing(forParagraphAt: 0)?.duration, 2.0)
        XCTAssertEqual(note.timing(forParagraphAt: 1)?.start, 2.0)
        XCTAssertEqual(note.timing(forParagraphAt: 1)?.duration, 3.5)
    }

    func testSaveAdoptsRecordingIntoStore() throws {
        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        let model = DictationViewModel(service: service, store: store, recordsAudio: true)
        service.emitFinalized("Recorded.", range: ParagraphTiming(start: 0, duration: 1.5))

        let note = try XCTUnwrap(try model.finish())
        let audioURL = try XCTUnwrap(store.audioURL(for: note.id))
        // The recording was moved into the note's audio slot.
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(note.audioFileName, audioURL.lastPathComponent)
        // The temp file was consumed (moved), not left behind.
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.stubRecordingURL!.path))
    }

    func testTranscriptOnlySavesNoAudioEvenIfServiceOffersARecording() throws {
        let service = RecordingStubCaptureService()
        // Even if a URL were present, transcript-only never adopts it.
        service.stubRecordingURL = try makeTempRecordingURL()
        let model = DictationViewModel(service: service, store: store, recordsAudio: false)
        service.emitFinalized("Words only.", range: nil)

        let note = try XCTUnwrap(try model.finish())
        XCTAssertFalse(note.hasAudio)
        XCTAssertNil(store.audioURL(for: note.id).flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        })
    }

    // MARK: - Read that back: recording vs fallback

    func testReadThatBackPlaysRecordedRange() async throws {
        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        let speaker = StubSpeaker()
        let player = StubAudioNotePlayer()
        let model = DictationViewModel(
            service: service, store: store, processor: MiraTextProcessor(),
            speaker: speaker, audioPlayer: player, recordsAudio: true
        )

        await model.begin()
        service.emitFinalized("Play me back.", range: ParagraphTiming(start: 4.0, duration: 2.5))
        service.emitFinalized("Mira read that back", range: nil)

        // The actual recording of the last paragraph plays at its range; TTS is not used.
        XCTAssertEqual(player.plays.count, 1)
        XCTAssertEqual(player.plays.first?.start, 4.0)
        XCTAssertEqual(player.plays.first?.duration, 2.5)
        XCTAssertTrue(speaker.spoken.isEmpty)

        // Finishing playback resumes capture (the shared read-back handshake).
        player.finish()
        XCTAssertEqual(service.resumeCount, 1)
    }

    func testReadThatBackFallsBackToSpeakerWithoutAudio() async throws {
        let service = RecordingStubCaptureService()
        // No recording URL: the paragraph has no playable audio, so it falls back to TTS.
        let speaker = StubSpeaker()
        let player = StubAudioNotePlayer()
        let model = DictationViewModel(
            service: service, store: store, processor: MiraTextProcessor(),
            speaker: speaker, audioPlayer: player, recordsAudio: false
        )

        await model.begin()
        service.emitFinalized("Speak me back.", range: nil)
        service.emitFinalized("Mira read that back", range: nil)

        XCTAssertTrue(player.plays.isEmpty)
        XCTAssertEqual(speaker.spoken, ["Speak me back."])

        speaker.finish()
        XCTAssertEqual(service.resumeCount, 1)
    }

    private func makeTempRecordingURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).m4a")
        try Data("audio-bytes".utf8).write(to: url)
        return url
    }
}

// MARK: - Test doubles

/// A capture-service stub that arms recording, exposes a stubbed recording URL, and emits finalized
/// segments with ranges so paragraph <-> time mapping and playback can be driven without live audio.
@MainActor
private final class RecordingStubCaptureService: SpeechCaptureService {
    var onEvent: ((SpeechCaptureEvent) -> Void)?
    private(set) var recordingEnabled = false
    private(set) var resumeCount = 0
    var stubRecordingURL: URL?

    func requestAuthorization() async -> SpeechCaptureError? { nil }
    func availabilityError() -> SpeechCaptureError? { nil }
    func setRecordingEnabled(_ enabled: Bool) { recordingEnabled = enabled }
    func recordingURL() -> URL? { stubRecordingURL }
    func start() {}
    func pause() {}
    func resume() { resumeCount += 1 }
    func stop() {}

    func emitFinalized(_ text: String, range: ParagraphTiming?) {
        onEvent?(.finalizedSegment(text, range: range))
    }
}

/// Records what range was played and lets the test drive the finish callback.
@MainActor
private final class StubAudioNotePlayer: AudioNotePlayer {
    var onFinish: (() -> Void)?
    private(set) var plays: [(url: URL, start: Double, duration: Double?)] = []

    @discardableResult
    func play(url: URL, from start: Double, duration: Double?) -> Bool {
        plays.append((url, start, duration))
        return true
    }

    func stop() {}
    func finish() { onFinish?() }
}

/// A `Speaker` stub that records what was spoken and drives its finish callback.
@MainActor
private final class StubSpeaker: Speaker {
    var onFinish: (() -> Void)?
    private(set) var spoken: [String] = []
    func speak(_ text: String) { spoken.append(text) }
    func stop() {}
    func finish() { onFinish?() }
}
