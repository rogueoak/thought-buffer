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

        // Wait for the background concatenation to land: the new paragraph's timing offset to start 9.0.
        let reloaded = try await awaitReSave(concatenator: concatenator, id: id, paragraphIndex: 1, expectedStart: 9.0)
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

    // MARK: - Multiple new paragraphs all offset past the existing audio

    func testMultipleNewParagraphsAreEachOffsetPastExisting() async throws {
        let original = try makeThoughtWithRecording() // one paragraph, recording is 8s
        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        let combined = try makeTempRecordingURL(contents: "combined")
        let concatenator = StubAudioConcatenator(
            result: .concatenated(combinedFileURL: combined, existingDuration: 8.0))
        let model = DictationViewModel(
            service: service, store: store, recordsAudio: true,
            audioConcatenator: concatenator, resuming: original
        )

        // Two new paragraphs, each with a real range relative to the new segment (a >1.5s gap forces a
        // separate paragraph). Offset should push both past the 8s existing audio.
        service.emitFinalized("First new.", range: ParagraphTiming(start: 0.5, duration: 1.0))
        service.emitFinalized("Second new.", range: ParagraphTiming(start: 4.0, duration: 1.0))

        let saved = try XCTUnwrap(try model.finish())
        let reloaded = try await awaitReSave(concatenator: concatenator, id: saved.id, paragraphIndex: 1, expectedStart: 8.5)

        XCTAssertEqual(reloaded.paragraphs.count, 3)
        XCTAssertEqual(reloaded.timing(forParagraphAt: 0)?.start ?? -1, 0.0, accuracy: 0.001, "existing untouched")
        XCTAssertEqual(reloaded.timing(forParagraphAt: 1)?.start ?? -1, 8.5, accuracy: 0.001, "8.0 + 0.5")
        XCTAssertEqual(reloaded.timing(forParagraphAt: 2)?.start ?? -1, 12.0, accuracy: 0.001, "8.0 + 4.0")
    }

    // MARK: - Concurrent edit changing the paragraph count keeps the fresh thought's own timings

    func testConcurrentEditChangingParagraphCountKeepsFreshTimings() async throws {
        let original = try makeThoughtWithRecording()
        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        let combined = try makeTempRecordingURL(contents: "combined")
        let concatenator = StubAudioConcatenator(
            result: .concatenated(combinedFileURL: combined, existingDuration: 8.0))
        concatenator.pauseUntilReleased = true
        let model = DictationViewModel(
            service: service, store: store, recordsAudio: true,
            audioConcatenator: concatenator, resuming: original
        )
        service.emitFinalized("Newly spoken addition.", range: ParagraphTiming(start: 1.0, duration: 2.0))
        let saved = try XCTUnwrap(try model.finish())

        // While the join is paused mid-flight, the user edits the thought on the detail screen and ADDS a
        // paragraph, so the on-disk paragraph count (3) no longer matches the captured timings (2).
        await concatenator.awaitInvocation()
        let onDisk = try XCTUnwrap(store.loadAll().first { $0.id == saved.id })
        let edited = onDisk.editedCopy(
            paragraphs: onDisk.paragraphs + ["A keyboard-added paragraph."],
            hasCustomTitle: false, customTitle: "")
        try store.save(edited)
        concatenator.release()

        // The combined audio still replaces the recording (the join is valid), but because the paragraph
        // count changed the offset timings are NOT applied - the fresh thought's own timings stand. The
        // user's added paragraph is preserved (no clobber).
        try await pollUntil {
            (try? Data(contentsOf: store.audioURL(for: saved.id)!)) == Data("combined".utf8)
        }
        let reloaded = try XCTUnwrap(store.loadAll().first { $0.id == saved.id })
        XCTAssertEqual(reloaded.paragraphs.count, 3, "the concurrent edit's added paragraph is preserved")
        XCTAssertEqual(reloaded.paragraphs.last, "A keyboard-added paragraph.")
    }

    // MARK: - Soft-delete racing the swap leaves no orphan and stays deleted

    func testThoughtSoftDeletedDuringJoinLeavesNoOrphanAndStaysDeleted() async throws {
        let original = try makeThoughtWithRecording()
        let id = original.id
        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        let combined = try makeTempRecordingURL(contents: "combined-secret-voice")
        let concatenator = StubAudioConcatenator(
            result: .concatenated(combinedFileURL: combined, existingDuration: 8.0))
        concatenator.pauseUntilReleased = true
        let model = DictationViewModel(
            service: service, store: store, recordsAudio: true,
            audioConcatenator: concatenator, resuming: original
        )
        service.emitFinalized("Newly spoken addition.", range: ParagraphTiming(start: 1.0, duration: 2.0))
        _ = try XCTUnwrap(try model.finish())
        let rootOrphan = tempDir.appendingPathComponent("\(id.uuidString).m4a")

        // The user soft-deletes the thought while the join is paused mid-flight.
        await concatenator.awaitInvocation()
        _ = try store.softDelete(id: id)
        XCTAssertNil(store.loadAll().first { $0.id == id }, "precondition: the thought is deleted")
        concatenator.release()

        // The doomed join must NOT resurrect the thought or leave an orphan raw-voice .m4a at the root.
        try await pollUntil { !FileManager.default.fileExists(atPath: combined.path) }
        XCTAssertNil(store.loadAll().first { $0.id == id }, "the thought stays deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootOrphan.path),
                       "no orphan raw-voice .m4a is left at the store root")
    }

    // MARK: - Boundary drift: a removed pre-existing paragraph still offsets a later new one (architect)

    func testRemovingPreExistingParagraphThenDictatingStillOffsetsTheNewParagraph() async throws {
        // A thought with TWO pre-existing spoken paragraphs and a recording.
        let id = UUID()
        let recURL = FileManager.default.temporaryDirectory.appendingPathComponent("orig-\(UUID().uuidString).m4a")
        try Data("original".utf8).write(to: recURL)
        let base = Thought(id: id, title: "Original",
                            paragraphs: ["Para one.", "Para two."],
                            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.save(base)
        let audioURL = try store.saveAudio(from: recURL, for: id)
        let withAudio = Thought(id: id, title: "Original", paragraphs: ["Para one.", "Para two."],
                                createdAt: base.createdAt, audioFileName: audioURL.lastPathComponent,
                                timings: [ParagraphTiming(start: 0, duration: 4), ParagraphTiming(start: 4, duration: 4)])
        try store.save(withAudio)

        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        let combined = try makeTempRecordingURL(contents: "combined")
        let concatenator = StubAudioConcatenator(
            result: .concatenated(combinedFileURL: combined, existingDuration: 8.0))
        let model = DictationViewModel(
            service: service, store: store, processor: MiraTextProcessor(controlWord: "mira"),
            recordsAudio: true, audioConcatenator: concatenator,
            controlWord: "mira", resuming: withAudio
        )

        // Remove the last (pre-existing) paragraph via a Mira command, shrinking the pre-existing region,
        // then dictate a NEW paragraph. Without the boundary clamp the new paragraph would land at index 1
        // (< the stale existingParagraphCount of 2) and never be offset.
        service.emitFinalized("mira remove last paragraph", range: nil)
        service.emitFinalized("A newly spoken paragraph.", range: ParagraphTiming(start: 1.0, duration: 2.0))

        let saved = try XCTUnwrap(try model.finish())
        XCTAssertEqual(saved.paragraphs, ["Para one.", "A newly spoken paragraph."],
                       "one pre-existing removed, one new appended")
        // The new paragraph (now index 1) is correctly treated as NEW and offset past the 8s existing audio.
        let reloaded = try await awaitReSave(concatenator: concatenator, id: saved.id, paragraphIndex: 1, expectedStart: 9.0)
        XCTAssertEqual(reloaded.timing(forParagraphAt: 0)?.start ?? -1, 0.0, accuracy: 0.001, "kept pre-existing")
        XCTAssertEqual(reloaded.timing(forParagraphAt: 1)?.start ?? -1, 9.0, accuracy: 0.001,
                       "the new paragraph is offset, not mistaken for pre-existing after the removal")
    }

    // MARK: - Soft-delete racing the POST-swap window does not resurrect the thought's text (security)

    /// SECURITY REGRESSION (feedback 0022 panel, security MAJOR): there is a SECOND delete-race window
    /// AFTER `replaceAudio` succeeds but BEFORE the final timings `save`. A soft-delete landing there moves
    /// `<id>.md` into `.trash/`, and without a guard the final `save` would write a FRESH `<id>.md` at root,
    /// RESURRECTING the deleted thought's title + paragraphs as a live, audio-less thought. The re-confirm
    /// before the save must SKIP the save when the thought is gone. Uses a store wrapper that pauses INSIDE
    /// `replaceAudio` AFTER the real swap, so the delete lands strictly in the post-swap / pre-save window.
    func testSoftDeleteAfterSwapBeforeFinalSaveDoesNotResurrectThought() async throws {
        let raceStore = PostSwapRaceStore(inner: store)
        let original = try makeThoughtWithRecording()
        let id = original.id
        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        let combined = try makeTempRecordingURL(contents: "combined-after-swap")
        let concatenator = StubAudioConcatenator(
            result: .concatenated(combinedFileURL: combined, existingDuration: 8.0))
        let model = DictationViewModel(
            service: service, store: raceStore, recordsAudio: true,
            audioConcatenator: concatenator, resuming: original
        )
        service.emitFinalized("Newly spoken addition.", range: ParagraphTiming(start: 1.0, duration: 2.0))
        _ = try XCTUnwrap(try model.finish())
        let rootMd = tempDir.appendingPathComponent("\(id.uuidString).md")

        // Wait until the swap has completed and `replaceAudio` is paused, THEN soft-delete (the delete
        // lands strictly after the swap, before the final save), then release.
        await raceStore.awaitPausedAfterSwap()
        _ = try store.softDelete(id: id)
        XCTAssertNil(store.loadAll().first { $0.id == id }, "precondition: deleted after the swap")
        raceStore.release()

        // The final save must be SKIPPED - the thought stays deleted and no <id>.md reappears at root.
        try await pollUntil { !FileManager.default.fileExists(atPath: combined.path) }
        // Give the (guarded) final-save path a chance to run and be skipped.
        try await pollUntil { raceStore.replaceReturned }
        XCTAssertNil(store.loadAll().first { $0.id == id }, "the thought stays deleted - no resurrection")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootMd.path),
                       "no fresh <id>.md is re-materialized at the store root")
    }

    // MARK: - Keyboard edit during a resume keeps the new paragraph offset (clamp holds)

    func testKeyboardEditDuringResumeKeepsNewParagraphOffset() async throws {
        // Two pre-existing spoken paragraphs + a recording (8s).
        let id = UUID()
        let recURL = FileManager.default.temporaryDirectory.appendingPathComponent("orig-\(UUID().uuidString).m4a")
        try Data("original".utf8).write(to: recURL)
        try store.save(Thought(id: id, title: "Original", paragraphs: ["Para one.", "Para two."],
                               createdAt: Date(timeIntervalSince1970: 1_700_000_000)))
        let audioURL = try store.saveAudio(from: recURL, for: id)
        let withAudio = Thought(id: id, title: "Original", paragraphs: ["Para one.", "Para two."],
                                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                audioFileName: audioURL.lastPathComponent,
                                timings: [ParagraphTiming(start: 0, duration: 4), ParagraphTiming(start: 4, duration: 4)])
        try store.save(withAudio)

        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        let combined = try makeTempRecordingURL(contents: "combined")
        let concatenator = StubAudioConcatenator(
            result: .concatenated(combinedFileURL: combined, existingDuration: 8.0))
        let model = DictationViewModel(
            service: service, store: store, recordsAudio: true,
            audioConcatenator: concatenator, resuming: withAudio
        )

        // The user edits the transcript via the keyboard, DROPPING a pre-existing paragraph (re-split to
        // one paragraph), then dictates a NEW one. The clamp must shrink existingParagraphCount from 2 to
        // 1 so the new paragraph (index 1) is still treated as NEW and offset past the 8s existing audio.
        model.applyEditedTranscript("Para one only.")
        service.emitFinalized("A newly spoken paragraph.", range: ParagraphTiming(start: 1.0, duration: 2.0))

        let saved = try XCTUnwrap(try model.finish())
        XCTAssertEqual(saved.paragraphs, ["Para one only.", "A newly spoken paragraph."])
        let reloaded = try await awaitReSave(concatenator: concatenator, id: saved.id, paragraphIndex: 1, expectedStart: 9.0)
        XCTAssertEqual(reloaded.timing(forParagraphAt: 1)?.start ?? -1, 9.0, accuracy: 0.001,
                       "after a keyboard edit that dropped a pre-existing paragraph, the new one is still offset")
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

    /// Poll a condition until it holds (bounded), so a test can wait on a detached task's effect without
    /// an arbitrary fixed sleep.
    private func pollUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Wait for the detached concatenation task's re-save to land: the concatenator signals invocation
    /// deterministically (`awaitInvocation`), then a brief bounded poll covers only the store re-save that
    /// follows. Fails LOUDLY on timeout rather than returning stale data, so a real offset regression
    /// surfaces as a clear timeout instead of a confusing value mismatch downstream.
    private func awaitReSave(
        concatenator: StubAudioConcatenator,
        id: UUID,
        paragraphIndex: Int,
        expectedStart: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Thought {
        await concatenator.awaitInvocation()
        for _ in 0..<100 {
            if let thought = store.loadAll().first(where: { $0.id == id }),
               let start = thought.timing(forParagraphAt: paragraphIndex)?.start,
               abs(start - expectedStart) < 0.001 {
                return thought
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for the concatenation re-save to offset paragraph \(paragraphIndex) to \(expectedStart)",
                file: file, line: line)
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
/// await the detached concatenation task deterministically. Optionally PAUSES inside `concatenate` (after
/// signaling invocation) until `release()` is called, so a test can inject a concurrent edit / delete
/// before the join's re-save reads the thought back.
private final class StubAudioConcatenator: AudioConcatenating, @unchecked Sendable {
    private let result: AudioConcatenationResult
    private let lock = NSLock()
    private var invoked = false
    private var invocationWaiters: [CheckedContinuation<Void, Never>] = []

    var pauseUntilReleased = false
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(result: AudioConcatenationResult) { self.result = result }

    /// Run `body` under `lock` and return its result. A SYNC helper so the async `concatenate` never calls
    /// `NSLock.lock()`/`unlock()` directly from an async context (unavailable there in Swift 6 mode).
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func concatenate(existing: URL, new: URL) async -> AudioConcatenationResult {
        let (toResume, mustPause) = withLock { () -> ([CheckedContinuation<Void, Never>], Bool) in
            invoked = true
            let waiters = invocationWaiters
            invocationWaiters.removeAll()
            return (waiters, pauseUntilReleased && !released)
        }
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

    func release() {
        lock.lock()
        released = true
        let toResume = releaseWaiters
        releaseWaiters.removeAll()
        lock.unlock()
        toResume.forEach { $0.resume() }
    }
}

/// A `ThoughtStoring` that forwards to a real `ThoughtStore` but PAUSES inside `replaceAudio` AFTER
/// performing the real swap, so a test can inject a soft-delete in the POST-swap / PRE-final-save window
/// (feedback 0022 security regression). Only the methods the concatenation path uses are forwarded; the
/// folder ops fall back to the protocol defaults (unused here). `@unchecked Sendable` because the
/// concatenation task runs off the main actor; the gate is a plain semaphore.
private final class PostSwapRaceStore: ThoughtStoring, @unchecked Sendable {
    private let inner: ThoughtStore
    private let pausedSignal = DispatchSemaphore(value: 0)
    private let releaseSignal = DispatchSemaphore(value: 0)
    private(set) var replaceReturned = false

    init(inner: ThoughtStore) { self.inner = inner }

    func replaceAudio(from temporaryURL: URL, for id: UUID) throws -> URL? {
        // Do the REAL swap first, then pause so a delete can land after the swap but before the save.
        let result = try inner.replaceAudio(from: temporaryURL, for: id)
        pausedSignal.signal()
        releaseSignal.wait()
        replaceReturned = true
        return result
    }

    /// Suspend until `replaceAudio` has done the real swap and is paused.
    func awaitPausedAfterSwap() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                self.pausedSignal.wait()
                continuation.resume()
            }
        }
    }

    func release() { releaseSignal.signal() }

    // Forwarded to the real store.
    @discardableResult func save(_ thought: Thought) throws -> URL { try inner.save(thought) }
    func loadAll() -> [Thought] { inner.loadAll() }
    func delete(id: UUID) throws { try inner.delete(id: id) }
    @discardableResult func softDelete(id: UUID) throws -> DeletedThought? { try inner.softDelete(id: id) }
    func audioURL(for id: UUID) -> URL? { inner.audioURL(for: id) }
    @discardableResult func saveAudio(from temporaryURL: URL, for id: UUID) throws -> URL {
        try inner.saveAudio(from: temporaryURL, for: id)
    }
}
