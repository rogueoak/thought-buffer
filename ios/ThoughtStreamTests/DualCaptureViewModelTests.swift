import XCTest
@testable import ThoughtStream

/// Dual-capture behavior in the view model (spec 0007): the tee is enabled per the retention flag,
/// finalized segments carry a range that maps to paragraphs, saving adopts the recording plus
/// timings, and "read that back" plays the correct range with a text-to-speech fallback.
@MainActor
final class DualCaptureViewModelTests: XCTestCase {
    private var tempDir: URL!
    private var store: ThoughtStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DualCaptureVM-\(UUID().uuidString)", isDirectory: true)
        store = ThoughtStore(directory: tempDir)
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

        let thought = try XCTUnwrap(try model.finish())
        XCTAssertEqual(thought.paragraphs, ["First paragraph.", "Second paragraph."])
        XCTAssertTrue(thought.hasAudio)
        XCTAssertEqual(thought.timings.count, 2)
        XCTAssertEqual(thought.timing(forParagraphAt: 0)?.start, 0.0)
        XCTAssertEqual(thought.timing(forParagraphAt: 0)?.duration, 2.0)
        XCTAssertEqual(thought.timing(forParagraphAt: 1)?.start, 2.0)
        XCTAssertEqual(thought.timing(forParagraphAt: 1)?.duration, 3.5)
    }

    /// Feedback 0012: two small-gap segments merge into ONE paragraph, and their timings merge into one
    /// contiguous range - the first segment's start through the second segment's absolute end - so
    /// playback still seeks the merged paragraph correctly and the arrays stay in lockstep.
    func testSmallGapMergesParagraphsAndTimings() throws {
        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        let model = DictationViewModel(service: service, store: store, recordsAudio: true)

        // First segment 0.0..2.0 (analysis start), then a breath: 2.5..3.5 (0.5s gap) -> same paragraph.
        service.emitFinalized(
            "Remember to call the supplier", range: ParagraphTiming(start: 0.0, duration: 2.0),
            startSeconds: 0.0, durationSeconds: 2.0, isAnalysisStart: true)
        service.emitFinalized(
            "before noon", range: ParagraphTiming(start: 2.5, duration: 1.0),
            startSeconds: 2.5, durationSeconds: 1.0, isAnalysisStart: false)

        let thought = try XCTUnwrap(try model.finish())
        XCTAssertEqual(thought.paragraphs, ["Remember to call the supplier before noon"],
                       "a mid-thought breath stays in one paragraph")
        XCTAssertEqual(thought.timings.count, 1, "one timing per merged paragraph")
        XCTAssertEqual(thought.timing(forParagraphAt: 0)?.start, 0.0)
        // Merged duration spans the first start (0.0) through the second's end (3.5).
        XCTAssertEqual(thought.timing(forParagraphAt: 0)?.duration, 3.5)
    }

    /// Feedback 0012 (PR #24 engineer-major review): a paragraph that began text-only (its first
    /// segment had no range) but gains a real recorded tail at a small gap ADOPTS the tail's range,
    /// instead of silently staying text-only and degrading to text-to-speech on playback.
    func testMergeAdoptsIncomingRangeWhenExistingTimingWasNil() throws {
        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        let model = DictationViewModel(service: service, store: store, recordsAudio: true)

        // First segment has no range; a small-gap tail WITH a real range merges in and is adopted.
        service.emitFinalized(
            "One", range: nil,
            startSeconds: 0.0, durationSeconds: 1.0, isAnalysisStart: true)
        service.emitFinalized(
            "two", range: ParagraphTiming(start: 1.2, duration: 1.0),
            startSeconds: 1.2, durationSeconds: 1.0, isAnalysisStart: false)

        let thought = try XCTUnwrap(try model.finish())
        XCTAssertEqual(thought.paragraphs, ["One two"])
        XCTAssertTrue(thought.hasAudio, "the merged paragraph adopts the recorded tail, not text-only")
        XCTAssertEqual(thought.timings.count, 1)
        XCTAssertEqual(thought.timing(forParagraphAt: 0)?.start, 1.2, "adopts the incoming tail's start")
        XCTAssertEqual(thought.timing(forParagraphAt: 0)?.duration, 1.0, "adopts the incoming tail's duration")
    }

    func testSaveAdoptsRecordingIntoStore() throws {
        let service = RecordingStubCaptureService()
        let tempURL = try makeTempRecordingURL()
        service.stubRecordingURL = tempURL
        let model = DictationViewModel(service: service, store: store, recordsAudio: true)
        service.emitFinalized("Recorded.", range: ParagraphTiming(start: 0, duration: 1.5))

        let thought = try XCTUnwrap(try model.finish())
        let audioURL = try XCTUnwrap(store.audioURL(for: thought.id))
        // The recording was moved into the thought's audio slot.
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(thought.audioFileName, audioURL.lastPathComponent)
        // The temp file was consumed (moved), not left behind.
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
    }

    func testTranscriptOnlySavesNoAudioEvenIfServiceOffersARecording() throws {
        let service = RecordingStubCaptureService()
        // Even if a URL were present, transcript-only never adopts it.
        service.stubRecordingURL = try makeTempRecordingURL()
        let model = DictationViewModel(service: service, store: store, recordsAudio: false)
        service.emitFinalized("Words only.", range: nil)

        let thought = try XCTUnwrap(try model.finish())
        XCTAssertFalse(thought.hasAudio)
        XCTAssertNil(store.audioURL(for: thought.id).flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        })
    }

    func testRecordingWithNoRealTimingsSavesTextOnlyWithNoOrphanAudio() throws {
        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        let model = DictationViewModel(service: service, store: store, recordsAudio: true)
        // Recording armed, but the only paragraph has no real range (a folded partial / edited text):
        // every resolved timing is zero-duration, so the thought must save text-only and adopt no audio.
        service.emitFinalized("No timing here.", range: nil)

        let thought = try XCTUnwrap(try model.finish())
        XCTAssertFalse(thought.hasAudio, "a thought with no real timing is text-only")
        // No orphan .m4a: the adopted file was cleaned up and the temp discarded.
        let audioURL = try XCTUnwrap(store.audioURL(for: thought.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    // MARK: - In-session read that back uses text-to-speech

    /// In-session read-back always speaks via TTS, even when the session is recording: the live
    /// `.m4a` is still open for writing (finalized only at Stop), so there is no finalized file to
    /// play. Recorded playback of the actual voice is a SAVED-thought feature through the shared
    /// `ThoughtPlaybackController` (covered in `ThoughtPlaybackControllerTests`).
    func testInSessionReadThatBackSpeaksViaTTSEvenWhenRecording() async throws {
        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        let speaker = StubSpeaker()
        let model = DictationViewModel(
            service: service, store: store, processor: MiraTextProcessor(),
            speaker: speaker, recordsAudio: true
        )

        await model.begin()
        service.emitFinalized("Read me back.", range: ParagraphTiming(start: 4.0, duration: 2.5))
        service.emitFinalized("Mira read that back", range: nil)

        // Spoken via TTS; capture paused for it.
        XCTAssertEqual(speaker.spoken, ["Read me back."])

        // Finishing the utterance resumes capture (the read-back handshake).
        speaker.finish()
        XCTAssertEqual(service.resumeCount, 1)
    }

    // MARK: - Mira edits keep paragraph timings aligned (the real invariant)

    /// Inject TWO timed paragraphs, remove the LAST paragraph by voice, save, and assert the
    /// SURVIVING paragraph still maps to ITS OWN timing (start 0.0, duration 2.0) - not the dropped
    /// paragraph's later offset - and that no stale/extra timing lingers. This pins the invariant that
    /// a Mira edit keeps `paragraphTimings` in lockstep with `paragraphs`, so an old index never maps
    /// to the wrong (or a removed) paragraph's range.
    func testRemoveLastParagraphKeepsSurvivingParagraphTimingAligned() throws {
        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        let model = DictationViewModel(
            service: service, store: store, processor: MiraTextProcessor(), recordsAudio: true
        )

        service.emitFinalized("First paragraph.", range: ParagraphTiming(start: 0.0, duration: 2.0))
        service.emitFinalized("Second paragraph.", range: ParagraphTiming(start: 2.0, duration: 3.5))
        // Command arrives as its own finalized segment (no range).
        service.emitFinalized("Mira remove the last paragraph", range: nil)

        XCTAssertEqual(model.paragraphs, ["First paragraph."], "the last paragraph was removed")

        let thought = try XCTUnwrap(try model.finish())
        XCTAssertEqual(thought.paragraphs, ["First paragraph."])
        XCTAssertTrue(thought.hasAudio)
        XCTAssertEqual(thought.timings.count, 1, "exactly one timing survives - no stale/extra entry")
        // The surviving paragraph keeps ITS timing (start 0.0), not the dropped paragraph's 2.0.
        XCTAssertEqual(thought.timing(forParagraphAt: 0)?.start, 0.0)
        XCTAssertEqual(thought.timing(forParagraphAt: 0)?.duration, 2.0)
    }

    /// Inject two timed paragraphs, remove the last SENTENCE, save, and assert the surviving
    /// paragraph still maps to start 0.0. Removing the last sentence empties the second (single
    /// sentence) paragraph, dropping it wholesale; the first paragraph's timing must be untouched.
    func testRemoveLastSentenceKeepsSurvivingParagraphTimingAligned() throws {
        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        let model = DictationViewModel(
            service: service, store: store, processor: MiraTextProcessor(), recordsAudio: true
        )

        service.emitFinalized("First paragraph.", range: ParagraphTiming(start: 0.0, duration: 2.0))
        service.emitFinalized("Second paragraph.", range: ParagraphTiming(start: 2.0, duration: 3.5))
        service.emitFinalized("Mira remove the last sentence", range: nil)

        // The second paragraph was a single sentence, so it is removed entirely.
        XCTAssertEqual(model.paragraphs, ["First paragraph."])

        let thought = try XCTUnwrap(try model.finish())
        XCTAssertEqual(thought.timings.count, 1, "no stale timing left from the removed paragraph")
        XCTAssertEqual(thought.timing(forParagraphAt: 0)?.start, 0.0)
        XCTAssertEqual(thought.timing(forParagraphAt: 0)?.duration, 2.0)
    }

    /// Removing the last sentence of a MULTI-sentence last paragraph shrinks it in place. Its recorded
    /// range no longer matches the edited text, so its timing is dropped (falls back to TTS), while
    /// the FIRST paragraph's timing stays aligned. Confirms the arrays never drift on an in-place edit.
    func testRemoveLastSentenceFromMultiSentenceParagraphDropsOnlyItsTiming() throws {
        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        let model = DictationViewModel(
            service: service, store: store, processor: MiraTextProcessor(), recordsAudio: true
        )

        service.emitFinalized("First paragraph.", range: ParagraphTiming(start: 0.0, duration: 2.0))
        service.emitFinalized("One. Two.", range: ParagraphTiming(start: 2.0, duration: 3.5))
        service.emitFinalized("Mira remove the last sentence", range: nil)

        XCTAssertEqual(model.paragraphs, ["First paragraph.", "One."])

        let thought = try XCTUnwrap(try model.finish())
        XCTAssertEqual(thought.timings.count, 2, "still 1:1 with paragraphs")
        XCTAssertEqual(thought.timing(forParagraphAt: 0)?.start, 0.0, "first paragraph timing untouched")
        XCTAssertEqual(thought.timing(forParagraphAt: 0)?.duration, 2.0)
        // The edited paragraph's timing was dropped to a zero-length placeholder (plays via TTS).
        XCTAssertEqual(thought.timing(forParagraphAt: 1)?.duration, 0.0)
    }

    // MARK: - Text-only thought gains audio on resume (spec 0013)

    /// Spec 0013 acceptance: resuming a TEXT-ONLY thought with `recordsAudio: true` and speaking a tail
    /// must save a thought that (a) keeps the original typed paragraphs, (b) appends the newly spoken
    /// paragraph, (c) attaches the newly captured recording, and (d) maps timings so the original
    /// paragraphs have zero-length placeholders (play back via TTS) while the spoken tail keeps its
    /// real recorded range. This is the inverse of the usual resume (which preserves an EXISTING
    /// recording): here the original had none, so the new audio is adopted.
    func testResumingTextOnlyThoughtWithRecordingAttachesAudioForNewTail() throws {
        // A typed thought with two paragraphs and NO recording (hasAudio == false).
        let original = Thought(
            title: "Typed thought",
            paragraphs: ["First typed paragraph.", "Second typed paragraph."],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertFalse(original.hasAudio, "precondition: the original thought carries no recording")

        let service = RecordingStubCaptureService()
        service.stubRecordingURL = try makeTempRecordingURL()
        let model = DictationViewModel(
            service: service, store: store, recordsAudio: true, resuming: original
        )

        // Speak a tail with a real recorded range (an absolute offset past the typed paragraphs).
        service.emitFinalized("Spoken addition.", range: ParagraphTiming(start: 0.0, duration: 2.5))

        let thought = try XCTUnwrap(try model.finish())

        // The original paragraphs are preserved and the spoken tail is appended, in order.
        XCTAssertEqual(thought.paragraphs, [
            "First typed paragraph.",
            "Second typed paragraph.",
            "Spoken addition."
        ])
        // The newly captured recording was adopted (the thought now has audio and a Play control shows).
        XCTAssertTrue(thought.hasAudio, "the thought gained a recording from the spoken tail")
        let audioURL = try XCTUnwrap(store.audioURL(for: thought.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path), "audio adopted into store")
        XCTAssertEqual(thought.audioFileName, audioURL.lastPathComponent)

        // Timings line up 1:1 with paragraphs: the two typed paragraphs get zero-length placeholders
        // (TTS on playback), the spoken tail keeps its real range.
        XCTAssertEqual(thought.timings.count, 3)
        XCTAssertEqual(thought.timing(forParagraphAt: 0)?.duration, 0.0, "typed paragraph plays via TTS")
        XCTAssertEqual(thought.timing(forParagraphAt: 1)?.duration, 0.0, "typed paragraph plays via TTS")
        XCTAssertEqual(thought.timing(forParagraphAt: 2)?.start, 0.0)
        XCTAssertEqual(thought.timing(forParagraphAt: 2)?.duration, 2.5, "the spoken tail keeps its range")
    }

    // MARK: - Cancelled / empty session leaves no audio on disk

    /// Cancelling a session discards the recording: the temp file is removed and no thought audio is
    /// left behind. Pins that a backed-out session never orphans an `.m4a`.
    func testCancelledSessionDiscardsRecordingFile() throws {
        let service = RecordingStubCaptureService()
        let tempURL = try makeTempRecordingURL()
        service.stubRecordingURL = tempURL
        let model = DictationViewModel(service: service, store: store, recordsAudio: true)
        service.emitFinalized("Something.", range: ParagraphTiming(start: 0, duration: 1.0))

        model.cancel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path), "temp recording is gone")
        XCTAssertEqual(service.discardCount, 1)
    }

    /// Finishing with nothing captured discards the recording and saves no thought - no orphan audio.
    func testEmptyFinishDiscardsRecordingAndSavesNothing() throws {
        let service = RecordingStubCaptureService()
        let tempURL = try makeTempRecordingURL()
        service.stubRecordingURL = tempURL
        let model = DictationViewModel(service: service, store: store, recordsAudio: true)

        XCTAssertNil(try model.finish(), "nothing captured, so no thought")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path), "empty session leaves no audio")
        XCTAssertEqual(store.loadAll().count, 0)
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
    private(set) var discardCount = 0
    var stubRecordingURL: URL?

    func requestAuthorization() async -> SpeechCaptureError? { nil }
    func availabilityError() -> SpeechCaptureError? { nil }
    func setRecordingEnabled(_ enabled: Bool) { recordingEnabled = enabled }
    func recordingURL() -> URL? { stubRecordingURL }
    func discardRecording() {
        discardCount += 1
        // Mirror the real service: discarding removes the temp file and drops it.
        if let url = stubRecordingURL { try? FileManager.default.removeItem(at: url) }
        stubRecordingURL = nil
    }
    func start() {}
    func pause() {}
    func resume() { resumeCount += 1 }
    func stop() {}

    /// Emit a finalized segment. `isAnalysisStart` defaults to true and the raw seconds to non-finite,
    /// so each emitted segment is its own paragraph (the pre-0012 "one finalized = one paragraph"
    /// behavior these dual-capture tests assert) unless a grouping test passes real gap timing.
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

/// A `Speaker` stub that records what was spoken and drives its finish callback.
@MainActor
private final class StubSpeaker: Speaker {
    var onFinish: (() -> Void)?
    private(set) var spoken: [String] = []
    func speak(_ text: String) { spoken.append(text) }
    func stop() {}
    func finish() { onFinish?() }
}
