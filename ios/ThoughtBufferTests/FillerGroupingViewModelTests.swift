import XCTest
@testable import ThoughtBuffer

/// Spec 0016 x feedback 0012 interaction: a finalized segment that filler removal reduces to EMPTY
/// must be dropped WITHOUT creating a paragraph and WITHOUT advancing the paragraph grouper's gap
/// anchor. If a dropped filler-only segment poisoned the anchor, the NEXT real segment's gap would be
/// measured against the wrong point and paragraph boundaries would shift. These tests drive the view
/// model with a filler-enabled processor and real gap timing to pin that.
@MainActor
final class FillerGroupingViewModelTests: XCTestCase {
    private var tempDir: URL!
    private var store: ThoughtStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FillerGroupingVM-\(UUID().uuidString)", isDirectory: true)
        store = ThoughtStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    /// A composite processor with the filler stage ON, matching a real refine-enabled session.
    private func refiningModel(_ service: FillerGroupingStubService) -> DictationViewModel {
        let processor = CompositeTextProcessor(controlWord: "Mira", overrides: [], removesFillers: true)
        return DictationViewModel(service: service, store: store, processor: processor)
    }

    func testFillerOnlySegmentCreatesNoParagraph() {
        let service = FillerGroupingStubService()
        let model = refiningModel(service)

        service.emitFinalized("First thought.", startSeconds: 0.0, durationSeconds: 1.0, isAnalysisStart: true)
        // Nothing but fillers: it must drop, adding no paragraph.
        service.emitFinalized("um uh hmm", startSeconds: 1.2, durationSeconds: 0.3, isAnalysisStart: false)

        XCTAssertEqual(model.paragraphs, ["First thought."],
                       "a filler-only segment must not create a paragraph")
    }

    func testDroppedFillerSegmentDoesNotShiftParagraphBoundary() {
        let service = FillerGroupingStubService()
        let model = refiningModel(service)

        // Segment A ends at t=1.0 (the grouper's anchor).
        service.emitFinalized("First thought", startSeconds: 0.0, durationSeconds: 1.0, isAnalysisStart: true)

        // A filler-only segment ending at t=2.0. It DROPS. If it wrongly advanced the anchor to 2.0,
        // segment B's gap below would read 0.9 (< 1.5) and B would APPEND, collapsing to one paragraph.
        service.emitFinalized("um uh", startSeconds: 1.5, durationSeconds: 0.5, isAnalysisStart: false)

        // Segment B starts at t=2.9. Measured from the TRUE anchor (1.0) the gap is 1.9 (>= 1.5), so B
        // is a NEW paragraph. This only holds if the dropped filler segment left the anchor at 1.0.
        service.emitFinalized("second thought", startSeconds: 2.9, durationSeconds: 1.0, isAnalysisStart: false)

        XCTAssertEqual(
            model.paragraphs,
            ["First thought", "second thought"],
            "a dropped filler segment must not poison the grouper anchor or the next boundary"
        )
    }

    func testFillerStrippedFromCommittedParagraph() {
        // A segment that mixes fillers and real words commits the cleaned text as a paragraph.
        let service = FillerGroupingStubService()
        let model = refiningModel(service)

        service.emitFinalized("um so, uh, the plan", startSeconds: 0.0, durationSeconds: 1.5, isAnalysisStart: true)

        XCTAssertEqual(model.paragraphs, ["So, the plan"])
    }
}

/// A minimal `SpeechCaptureService` stub that emits finalized segments with explicit gap timing, so a
/// grouping test can drive the pause-based `ParagraphGrouper` deterministically without audio.
@MainActor
private final class FillerGroupingStubService: SpeechCaptureService {
    var onEvent: ((SpeechCaptureEvent) -> Void)?

    func requestAuthorization() async -> SpeechCaptureError? { nil }
    func availabilityError() -> SpeechCaptureError? { nil }
    func setRecordingEnabled(_ enabled: Bool) {}
    func recordingURL() -> URL? { nil }
    func discardRecording() {}
    func start() {}
    func pause() {}
    func resume() {}
    func stop() {}

    func emitFinalized(
        _ text: String,
        startSeconds: Double,
        durationSeconds: Double,
        isAnalysisStart: Bool
    ) {
        onEvent?(.finalizedSegment(
            text,
            range: nil,
            startSeconds: startSeconds,
            durationSeconds: durationSeconds,
            isAnalysisStart: isAnalysisStart
        ))
    }
}
