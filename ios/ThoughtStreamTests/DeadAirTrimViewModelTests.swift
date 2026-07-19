import XCTest
@testable import ThoughtStream

/// The view-model wiring for dead-air removal (spec 0019): on save, an ON session (a trimmer present)
/// trims the freshly adopted recording off the main actor and re-saves the note with remapped
/// timings; an OFF session (nil trimmer) never touches the audio and never invokes a trim.
@MainActor
final class DeadAirTrimViewModelTests: XCTestCase {
    private var tempDir: URL!
    private var store: NoteStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeadAirVM-\(UUID().uuidString)", isDirectory: true)
        store = NoteStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - OFF path: nil trimmer never touches the audio

    func testTrimOffNeverInvokesATrimAndLeavesTimingsUntouched() throws {
        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        // No audioTrimmer injected -> trimming is OFF.
        let model = DictationViewModel(service: service, store: store, recordsAudio: true)

        service.emitFinalized("First.", range: ParagraphTiming(start: 0.0, duration: 2.0))
        service.emitFinalized("Second.", range: ParagraphTiming(start: 5.0, duration: 2.0))

        let note = try XCTUnwrap(try model.finish())
        // Timings are the raw captured ones (no remap applied) and the note has audio.
        XCTAssertTrue(note.hasAudio)
        XCTAssertEqual(note.timing(forParagraphAt: 1)?.start, 5.0, "OFF leaves the original timeline")
    }

    // MARK: - ON path: trim runs, timings remap, note re-saved

    func testTrimOnRemapsTimingsAndReSaves() async throws {
        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        // The stub trimmer reports removing 3.0s at [2.0, 5.0) - the gap before the second paragraph.
        let trimmer = StubAudioTrimmer(result: .trimmed(removedRanges: [
            SilenceTrimmer.KeepRange(start: 2.0, end: 5.0)
        ]))
        let model = DictationViewModel(
            service: service, store: store, recordsAudio: true, audioTrimmer: trimmer
        )

        service.emitFinalized("First.", range: ParagraphTiming(start: 0.0, duration: 2.0))
        service.emitFinalized("Second.", range: ParagraphTiming(start: 5.0, duration: 2.0))

        let note = try XCTUnwrap(try model.finish())
        let id = note.id

        // The trim runs on a detached task; wait for it to fire and re-save.
        await trimmer.awaitInvocation()

        // Poll the store for the re-saved note with remapped timings (second paragraph shifted left 3s).
        let reloaded = try await pollForRemap(id: id, expectedSecondStart: 2.0)
        XCTAssertEqual(reloaded.timing(forParagraphAt: 0)?.start ?? -1, 0.0, accuracy: 0.001)
        XCTAssertEqual(reloaded.timing(forParagraphAt: 1)?.start ?? -1, 2.0, accuracy: 0.001,
                       "second paragraph shifted left by the 3s removed before it")
        XCTAssertTrue(reloaded.hasAudio, "the note keeps its (now trimmed) recording")
    }

    func testTrimReturningNotTrimmedLeavesTimingsUnchanged() async throws {
        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        let trimmer = StubAudioTrimmer(result: .notTrimmed)
        let model = DictationViewModel(
            service: service, store: store, recordsAudio: true, audioTrimmer: trimmer
        )

        service.emitFinalized("First.", range: ParagraphTiming(start: 0.0, duration: 2.0))
        service.emitFinalized("Second.", range: ParagraphTiming(start: 5.0, duration: 2.0))

        let note = try XCTUnwrap(try model.finish())
        await trimmer.awaitInvocation()

        // Give the (no-op) detached task a beat, then confirm the stored timings are unchanged.
        try await Task.sleep(nanoseconds: 100_000_000)
        let reloaded = try XCTUnwrap(store.loadAll().first { $0.id == note.id })
        XCTAssertEqual(reloaded.timing(forParagraphAt: 1)?.start, 5.0, "no remap on a not-trimmed result")
    }

    // MARK: - Helpers

    /// Poll the store until the note's second-paragraph start matches the expected remapped value, so
    /// the test does not race the detached re-save.
    private func pollForRemap(id: UUID, expectedSecondStart: Double) async throws -> Note {
        for _ in 0..<50 {
            if let note = store.loadAll().first(where: { $0.id == id }),
               let start = note.timing(forParagraphAt: 1)?.start,
               abs(start - expectedSecondStart) < 0.001 {
                return note
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try XCTUnwrap(store.loadAll().first { $0.id == id })
    }

    private func makeTempRecordingURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).m4a")
        try Data("audio-bytes".utf8).write(to: url)
        return url
    }
}

// MARK: - Test doubles

/// A capture-service stub arming recording and emitting finalized segments (mirrors the one in the
/// dual-capture suite; duplicated privately so the two suites stay independent).
@MainActor
private final class RecordingStubCaptureService: SpeechCaptureService {
    var onEvent: ((SpeechCaptureEvent) -> Void)?
    private(set) var recordingEnabled = false
    var stubRecordingURL: URL?

    func requestAuthorization() async -> SpeechCaptureError? { nil }
    func availabilityError() -> SpeechCaptureError? { nil }
    func setRecordingEnabled(_ enabled: Bool) { recordingEnabled = enabled }
    func recordingURL() -> URL? { stubRecordingURL }
    func discardRecording() {
        if let url = stubRecordingURL { try? FileManager.default.removeItem(at: url) }
        stubRecordingURL = nil
    }
    func start() {}
    func pause() {}
    func resume() {}
    func stop() {}

    func emitFinalized(
        _ text: String,
        range: ParagraphTiming?,
        startSeconds: Double = .nan,
        durationSeconds: Double = .nan,
        isAnalysisStart: Bool = true
    ) {
        onEvent?(.finalizedSegment(
            text,
            range: range,
            startSeconds: startSeconds,
            durationSeconds: durationSeconds,
            isAnalysisStart: isAnalysisStart
        ))
    }
}

/// A stub `AudioTrimming` that returns a fixed result and signals when it was invoked, so a test can
/// await the detached trim task deterministically.
private final class StubAudioTrimmer: AudioTrimming, @unchecked Sendable {
    private let result: AudioTrimResult
    private let lock = NSLock()
    private var invoked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(result: AudioTrimResult) {
        self.result = result
    }

    func trim(fileAt url: URL) async -> AudioTrimResult {
        lock.lock()
        invoked = true
        let toResume = waiters
        waiters.removeAll()
        lock.unlock()
        toResume.forEach { $0.resume() }
        return result
    }

    /// Suspend until `trim` has been called at least once.
    func awaitInvocation() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if invoked {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
