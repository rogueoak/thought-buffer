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

    func testTrimOnAdoptsTrimmedAudioRemapsTimingsAndReSaves() async throws {
        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        // The stub reports removing 3.0s at [2.0, 5.0) - the gap before the second paragraph - and
        // hands back a trimmed temp file the view model must adopt via the store's replaceAudio seam.
        let trimmedFile = try makeTempRecordingURL(contents: "trimmed-audio-bytes")
        let trimmer = StubAudioTrimmer(result: .trimmed(
            trimmedFileURL: trimmedFile,
            removedRanges: [SilenceTrimmer.KeepRange(start: 2.0, end: 5.0)]
        ))
        let model = DictationViewModel(
            service: service, store: store, recordsAudio: true, audioTrimmer: trimmer
        )

        service.emitFinalized("First.", range: ParagraphTiming(start: 0.0, duration: 2.0))
        service.emitFinalized("Second.", range: ParagraphTiming(start: 5.0, duration: 2.0))

        let note = try XCTUnwrap(try model.finish())
        let id = note.id
        let audioURL = try XCTUnwrap(store.audioURL(for: id))

        // Poll the store for the re-saved note with remapped timings (second paragraph shifted left 3s).
        let reloaded = try await pollForRemap(id: id, expectedSecondStart: 2.0)
        XCTAssertEqual(reloaded.timing(forParagraphAt: 0)?.start ?? -1, 0.0, accuracy: 0.001)
        XCTAssertEqual(reloaded.timing(forParagraphAt: 1)?.start ?? -1, 2.0, accuracy: 0.001,
                       "second paragraph shifted left by the 3s removed before it")
        XCTAssertTrue(reloaded.hasAudio, "the note keeps its (now trimmed) recording")

        // The trimmed audio was adopted into the note's slot (its bytes replaced the original), and the
        // trimmer's temp file was consumed by the coordinated replace.
        XCTAssertEqual(try Data(contentsOf: audioURL), Data("trimmed-audio-bytes".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trimmedFile.path),
                       "the trimmed temp file was consumed by replaceAudio")
    }

    /// Architect + engineer finding: a concurrent edit to the note (on the detail screen) while the
    /// background trim runs must be PRESERVED - the trim re-reads the note fresh and updates only its
    /// timings, so it never clobbers the edit with the stale snapshot captured at finish().
    func testTrimReReadsNoteSoAConcurrentEditIsNotClobbered() async throws {
        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        let trimmedFile = try makeTempRecordingURL(contents: "trimmed")
        let trimmer = StubAudioTrimmer(result: .trimmed(
            trimmedFileURL: trimmedFile,
            removedRanges: [SilenceTrimmer.KeepRange(start: 2.0, end: 5.0)]
        ))
        // Gate the trim so we can inject an edit BEFORE the re-save reads the note back.
        trimmer.pauseUntilReleased = true
        let model = DictationViewModel(
            service: service, store: store, recordsAudio: true, audioTrimmer: trimmer
        )
        service.emitFinalized("First.", range: ParagraphTiming(start: 0.0, duration: 2.0))
        service.emitFinalized("Second.", range: ParagraphTiming(start: 5.0, duration: 2.0))
        let note = try XCTUnwrap(try model.finish())

        // Simulate the user editing the note's title on the detail screen while the trim is in flight
        // (the trim is paused inside its invocation until we release it).
        await trimmer.awaitInvocation()
        let onDisk = try XCTUnwrap(store.loadAll().first { $0.id == note.id })
        let renamed = onDisk.editedCopy(
            paragraphs: onDisk.paragraphs, hasCustomTitle: true, customTitle: "User renamed this")
        try store.save(renamed)
        trimmer.release() // let the trim finish and re-save with remapped timings

        // The user's title survives, AND the timings are remapped - both changes coexist.
        let reloaded = try await pollForRemap(id: note.id, expectedSecondStart: 2.0)
        XCTAssertEqual(reloaded.title, "User renamed this", "the concurrent edit was not clobbered")
        XCTAssertTrue(reloaded.hasCustomTitle)
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
        // Wait until the trim has actually run and returned .notTrimmed (no arbitrary sleep).
        await trimmer.awaitInvocation()
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

    private func makeTempRecordingURL(contents: String = "audio-bytes") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).m4a")
        try Data(contents.utf8).write(to: url)
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
/// await the detached trim task deterministically. Optionally PAUSES inside `trim` (after signaling
/// invocation) until `release()` is called, so a test can inject a concurrent edit before the trim's
/// re-save reads the note back.
private final class StubAudioTrimmer: AudioTrimming, @unchecked Sendable {
    private let result: AudioTrimResult
    private let lock = NSLock()
    private var invoked = false
    private var invocationWaiters: [CheckedContinuation<Void, Never>] = []

    /// When true, `trim` blocks after signaling invocation until `release()` is called.
    var pauseUntilReleased = false
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(result: AudioTrimResult) {
        self.result = result
    }

    func trim(fileAt url: URL) async -> AudioTrimResult {
        lock.lock()
        invoked = true
        let toResume = invocationWaiters
        invocationWaiters.removeAll()
        let mustPause = pauseUntilReleased && !released
        lock.unlock()
        toResume.forEach { $0.resume() }

        if mustPause {
            await withCheckedContinuation { continuation in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                } else {
                    releaseWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }
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
                invocationWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Let a paused `trim` proceed to return its result.
    func release() {
        lock.lock()
        released = true
        let toResume = releaseWaiters
        releaseWaiters.removeAll()
        lock.unlock()
        toResume.forEach { $0.resume() }
    }
}
