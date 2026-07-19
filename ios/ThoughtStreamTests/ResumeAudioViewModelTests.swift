import XCTest
@testable import ThoughtStream

/// The view-model wiring for resume-continues-audio (feedback 0022): resuming a thought that ALREADY has
/// a recording, with recording on, captures a NEW segment that is CONCATENATED onto the existing
/// recording off the main actor, with the new paragraphs' timings offset past the original. On any
/// concatenation failure the original recording is kept and the new paragraphs stay text-only (no data
/// loss). A resume with recording OFF stays a text-only append, exactly as before.
@MainActor
final class ResumeAudioViewModelTests: XCTestCase {
    private var tempDir: URL!
    private var store: ThoughtStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResumeAudioVM-\(UUID().uuidString)", isDirectory: true)
        store = ThoughtStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    /// Save a thought WITH a recording on disk, so resuming it exercises the has-audio path. The original
    /// recording has one paragraph timed [0, 8) - so its `recordingDuration` is 8s.
    private func makeThoughtWithRecording() throws -> Thought {
        let id = UUID()
        // Adopt a fake recording into the thought's slot.
        let recURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("orig-\(UUID().uuidString).m4a")
        try Data("original-recording".utf8).write(to: recURL)
        // Save the thought file first so the audio lands beside it.
        let base = Thought(
            id: id,
            title: "Original",
            paragraphs: ["Original spoken paragraph."],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try store.save(base)
        let audioURL = try store.saveAudio(from: recURL, for: id)
        let withAudio = Thought(
            id: id,
            title: "Original",
            paragraphs: ["Original spoken paragraph."],
            createdAt: base.createdAt,
            audioFileName: audioURL.lastPathComponent,
            timings: [ParagraphTiming(start: 0.0, duration: 8.0)]
        )
        try store.save(withAudio)
        XCTAssertTrue(withAudio.hasAudio, "precondition: the thought has a recording")
        return withAudio
    }

    private func makeTempRecordingURL(contents: String = "new-segment") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("newseg-\(UUID().uuidString).m4a")
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - Success: concatenation replaces the audio and offsets the new timings

    func testResumeWithAudioConcatenatesReplacesAudioAndOffsetsNewTimings() async throws {
        let original = try makeThoughtWithRecording()
        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()

        // The concatenator returns a combined file and reports the existing recording is 8s, so the new
        // paragraph (timed [1, 3) against the new segment) must offset to [9, 3) on the combined timeline.
        let combined = try makeTempRecordingURL(contents: "combined-original-plus-new")
        let concatenator = StubAudioConcatenator(
            result: .concatenated(combinedFileURL: combined, existingDuration: 8.0))

        let model = DictationViewModel(
            service: service, store: store, recordsAudio: true,
            audioConcatenator: concatenator, resuming: original
        )

        // Speak a new paragraph with a real recorded range relative to the NEW segment's start.
        service.emitFinalized("Newly spoken addition.", range: ParagraphTiming(start: 1.0, duration: 2.0))

        let saved = try XCTUnwrap(try model.finish())
        let id = saved.id

        // finish() returns the FALLBACK thought: original recording kept, new paragraph text-only.
        XCTAssertEqual(saved.paragraphs, ["Original spoken paragraph.", "Newly spoken addition."])
        XCTAssertTrue(saved.hasAudio)

        // Poll for the background concatenation to land: the new paragraph's timing offset to start 9.0.
        let reloaded = try await pollForNewTimingStart(id: id, expected: 9.0)
        XCTAssertEqual(reloaded.timing(forParagraphAt: 0)?.start ?? -1, 0.0, accuracy: 0.001,
                       "the pre-existing paragraph's timing is unchanged")
        XCTAssertEqual(reloaded.timing(forParagraphAt: 1)?.start ?? -1, 9.0, accuracy: 0.001,
                       "the new paragraph is anchored 8s (existing duration) + 1s (its relative start)")
        XCTAssertEqual(reloaded.timing(forParagraphAt: 1)?.duration ?? -1, 2.0, accuracy: 0.001)

        // The combined audio replaced the thought's recording, and the concatenator's temp was consumed.
        let audioURL = try XCTUnwrap(store.audioURL(for: id))
        XCTAssertEqual(try Data(contentsOf: audioURL), Data("combined-original-plus-new".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: combined.path),
                       "the combined temp was consumed by replaceAudio")
    }

    // MARK: - Failure fallback: keeps original recording + text-only append

    func testConcatenationFailureKeepsOriginalRecordingAndTextOnlyAppend() async throws {
        let original = try makeThoughtWithRecording()
        let originalAudioURL = try XCTUnwrap(store.audioURL(for: original.id))
        let originalBytes = try Data(contentsOf: originalAudioURL)

        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        let concatenator = StubAudioConcatenator(result: .notConcatenated)

        let model = DictationViewModel(
            service: service, store: store, recordsAudio: true,
            audioConcatenator: concatenator, resuming: original
        )
        service.emitFinalized("Newly spoken addition.", range: ParagraphTiming(start: 1.0, duration: 2.0))

        let saved = try XCTUnwrap(try model.finish())
        // Wait until the concatenation attempt has actually run and returned .notConcatenated.
        await concatenator.awaitInvocation()

        let reloaded = try XCTUnwrap(store.loadAll().first { $0.id == saved.id })
        // The words are kept (text-only append), the original recording is untouched.
        XCTAssertEqual(reloaded.paragraphs, ["Original spoken paragraph.", "Newly spoken addition."])
        XCTAssertTrue(reloaded.hasAudio, "the original recording is preserved")
        XCTAssertEqual(try Data(contentsOf: originalAudioURL), originalBytes,
                       "the original recording bytes are unchanged")
        // The pre-existing paragraph keeps its real timing; the new one is a text-only placeholder.
        XCTAssertEqual(reloaded.timing(forParagraphAt: 0)?.start ?? -1, 0.0, accuracy: 0.001)
        XCTAssertEqual(reloaded.timing(forParagraphAt: 1)?.duration ?? -1, 0.0, accuracy: 0.001,
                       "the new paragraph stays text-only (TTS on playback) on the fallback")
    }

    // MARK: - No concatenator (recording OFF, or a store that keeps no audio): text-only append

    func testResumeWithoutConcatenatorStaysTextOnlyAppendAndKeepsOriginal() throws {
        let original = try makeThoughtWithRecording()
        let originalAudioURL = try XCTUnwrap(store.audioURL(for: original.id))
        let originalBytes = try Data(contentsOf: originalAudioURL)

        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        // recordsAudio false, no concatenator: the pre-0022 text-only-append behavior.
        let model = DictationViewModel(
            service: service, store: store, recordsAudio: false, resuming: original
        )
        service.emitFinalized("Typed-ish addition.", range: nil)

        let saved = try XCTUnwrap(try model.finish())
        XCTAssertEqual(saved.paragraphs, ["Original spoken paragraph.", "Typed-ish addition."])
        XCTAssertTrue(saved.hasAudio, "the original recording is preserved")
        XCTAssertEqual(try Data(contentsOf: originalAudioURL), originalBytes)
    }

    // MARK: - Helpers

    private func pollForNewTimingStart(id: UUID, expected: Double) async throws -> Thought {
        for _ in 0..<50 {
            if let thought = store.loadAll().first(where: { $0.id == id }),
               let start = thought.timing(forParagraphAt: 1)?.start,
               abs(start - expected) < 0.001 {
                return thought
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try XCTUnwrap(store.loadAll().first { $0.id == id })
    }
}

// MARK: - Test doubles

/// A capture-service stub arming recording and emitting finalized segments (private to this suite).
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

    func emitFinalized(_ text: String, range: ParagraphTiming?) {
        onEvent?(.finalizedSegment(
            text, range: range, startSeconds: .nan, durationSeconds: .nan, isAnalysisStart: true))
    }
}

/// A stub `AudioConcatenating` returning a fixed result and signaling when it was invoked, so a test can
/// await the detached concatenation task deterministically.
private final class StubAudioConcatenator: AudioConcatenating, @unchecked Sendable {
    private let result: AudioConcatenationResult
    private let lock = NSLock()
    private var invoked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(result: AudioConcatenationResult) { self.result = result }

    func concatenate(existing: URL, new: URL) async -> AudioConcatenationResult {
        lock.lock()
        invoked = true
        let toResume = waiters
        waiters.removeAll()
        lock.unlock()
        toResume.forEach { $0.resume() }
        return result
    }

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
