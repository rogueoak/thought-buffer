import XCTest
@testable import ThoughtBuffer

/// Command execution in the view model: thought mutations, new thought (save + reset), read-back
/// (Speaker + capture pause/resume), and TextProcessor result routing (command consumed vs text
/// committed). Driven without live audio by injecting finalized segments.
@MainActor
final class MiraCommandExecutionTests: XCTestCase {
    private var store: RecordingThoughtStore!

    override func setUp() {
        super.setUp()
        store = RecordingThoughtStore()
    }

    private func makeModel(
        service: SpeechCaptureService? = nil,
        speaker: Speaker? = nil
    ) -> DictationViewModel {
        DictationViewModel(
            service: service ?? StubCaptureService(),
            store: store,
            processor: MiraTextProcessor(),
            speaker: speaker ?? StubSpeaker()
        )
    }

    // MARK: - TextProcessor routing

    func testCommandSegmentIsConsumedNotCommitted() {
        let model = makeModel()
        model.injectFinalized("First paragraph.")
        model.injectFinalized("Mira remove the last paragraph")
        // The command phrase never lands in the thought, and it removed the one paragraph.
        XCTAssertEqual(model.paragraphs, [])
    }

    func testOrdinaryTextIsCommitted() {
        let model = makeModel()
        model.injectFinalized("A perfectly ordinary sentence.")
        XCTAssertEqual(model.paragraphs, ["A perfectly ordinary sentence."])
    }

    // MARK: - Remove last sentence

    func testRemoveLastSentence() {
        let model = makeModel()
        model.injectFinalized("Call the supplier. Draft the email.")
        model.injectFinalized("Mira remove the last sentence")
        XCTAssertEqual(model.paragraphs, ["Call the supplier."])
    }

    func testRemoveLastSentenceEmptiesParagraphAndDropsIt() {
        let model = makeModel()
        model.injectFinalized("A single thought.")
        model.injectFinalized("Mira remove the last sentence")
        XCTAssertEqual(model.paragraphs, [])
    }

    func testRemoveLastSentenceOnEmptyThoughtIsNoOp() {
        let model = makeModel()
        model.injectFinalized("Mira remove the last sentence")
        XCTAssertEqual(model.paragraphs, [])
    }

    // MARK: - Remove last paragraph

    func testRemoveLastParagraph() {
        let model = makeModel()
        model.injectFinalized("First.")
        model.injectFinalized("Second.")
        model.injectFinalized("Mira remove the last paragraph")
        XCTAssertEqual(model.paragraphs, ["First."])
    }

    func testRemoveLastParagraphOnEmptyThoughtIsNoOp() {
        let model = makeModel()
        model.injectFinalized("Mira remove the last paragraph")
        XCTAssertEqual(model.paragraphs, [])
    }

    // MARK: - New thought

    func testNewThoughtSavesCurrentAndResets() {
        let model = makeModel()
        model.injectFinalized("A thought worth keeping.")
        model.injectFinalized("Mira new thought")

        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(store.saved.first?.paragraphs, ["A thought worth keeping."])
        XCTAssertEqual(model.paragraphs, [], "the thought should reset after new thought")

        // The fresh thought is independent: a second save writes a new file with a new id.
        model.injectFinalized("A second, separate thought.")
        model.injectFinalized("Mira new thought")
        XCTAssertEqual(store.saved.count, 2)
        XCTAssertNotEqual(store.saved[0].id, store.saved[1].id)
    }

    func testNewThoughtFoldsLivePartialIntoSavedThought() {
        let model = makeModel()
        model.injectFinalized("First finalized paragraph.")
        // A partial phrase is live (never finalized) when "Mira new thought" fires; it must fold into
        // the saved thought rather than being dropped.
        model.simulatePartial("A trailing partial thought")
        model.injectFinalized("Mira new thought")

        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(store.saved.first?.paragraphs, [
            "First finalized paragraph.",
            "A trailing partial thought"
        ])
        XCTAssertEqual(model.paragraphs, [])
    }

    func testNewThoughtWithEmptyThoughtSavesNothing() {
        let model = makeModel()
        model.injectFinalized("Mira new thought")
        XCTAssertEqual(store.saved.count, 0)
        XCTAssertEqual(model.paragraphs, [])
    }

    // MARK: - Read that back

    func testReadThatBackSpeaksLastParagraphAndCyclesCapture() async {
        let speaker = StubSpeaker()
        let service = StubCaptureService()
        let model = makeModel(service: service, speaker: speaker)

        // Bring the model to the recording phase so read-back pauses/resumes capture.
        await model.begin()
        XCTAssertTrue(model.isRecording)

        model.injectFinalized("First paragraph.")
        model.injectFinalized("The paragraph to read back.")
        model.injectFinalized("Mira read that back")

        XCTAssertEqual(speaker.spoken, ["The paragraph to read back."])
        // Capture paused for playback; nothing was committed for the command phrase.
        XCTAssertEqual(service.pauseCount, 1)
        XCTAssertEqual(service.resumeCount, 0)
        XCTAssertEqual(model.paragraphs, ["First paragraph.", "The paragraph to read back."])

        // When the utterance finishes, capture resumes.
        speaker.finish()
        XCTAssertEqual(service.resumeCount, 1)
    }

    func testReadThatBackOnEmptyThoughtDoesNotSpeak() {
        let speaker = StubSpeaker()
        let model = makeModel(speaker: speaker)
        model.injectFinalized("Mira read that back")
        XCTAssertTrue(speaker.spoken.isEmpty)
    }

    /// Regression for the stuck-state race: a Pause tapped WHILE Mira is reading back must leave
    /// the session in a consistent, non-stuck state, and capture must not be permanently torn down.
    func testPauseDuringReadBackEndsPausedThenResumesCleanly() async {
        let speaker = StubSpeaker()
        let service = StubCaptureService()
        let model = makeModel(service: service, speaker: speaker)

        await model.begin()
        model.injectFinalized("The paragraph to read back.")
        model.injectFinalized("Mira read that back")

        // Read-back paused capture; the UI reflects the read-back state, not a stuck "recording".
        XCTAssertEqual(service.pauseCount, 1)
        XCTAssertEqual(model.phase, .readingBack)

        // The user taps Pause mid-playback. The session becomes paused; capture is not re-torn-down.
        model.togglePause()
        XCTAssertEqual(model.phase, .paused)
        XCTAssertEqual(service.pauseCount, 1)

        // When the utterance finishes it must NOT resume (the user paused) and must stay paused --
        // no permanent stuck state, no double resume.
        speaker.finish()
        XCTAssertEqual(model.phase, .paused)
        XCTAssertEqual(service.resumeCount, 0)

        // And the session is still live: a normal resume works afterward.
        model.togglePause()
        XCTAssertEqual(model.phase, .recording)
        XCTAssertEqual(service.resumeCount, 1)
    }

    // MARK: - Banner: fires for every command that has an effect, not just remove-last-paragraph

    func testRemoveLastSentenceFiresBanner() {
        let model = makeModel()
        model.injectFinalized("Call the supplier. Draft the email.")
        model.injectFinalized("Mira remove the last sentence")
        XCTAssertEqual(model.commandBanner, "Mira - removed last sentence")
    }

    func testRemoveLastParagraphFiresBanner() {
        let model = makeModel()
        model.injectFinalized("First.")
        model.injectFinalized("Mira remove the last paragraph")
        XCTAssertEqual(model.commandBanner, "Mira - removed last paragraph")
    }

    func testNewThoughtFiresBanner() {
        let model = makeModel()
        model.injectFinalized("A thought worth keeping.")
        model.injectFinalized("Mira new thought")
        XCTAssertEqual(model.commandBanner, "Mira - new thought")
    }

    func testReadThatBackFiresBanner() {
        let model = makeModel()
        model.injectFinalized("The paragraph to read back.")
        model.injectFinalized("Mira read that back")
        XCTAssertEqual(model.commandBanner, "Mira - read that back")
    }

    // MARK: - Device accumulating-segment: command lands mid/end of one segment (feedback 0006)

    /// (a) "here is my thought Mira new thought" -> commits "here is my thought" AND fires newThought.
    func testAccumulatingSegmentCommitsPreTextAndFiresNewThought() {
        let model = makeModel()
        model.injectFinalized("here is my thought Mira new thought")
        // newThought saved the pre-text thought and reset, so the current thought is empty again.
        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(store.saved.first?.paragraphs, ["here is my thought"])
        XCTAssertEqual(model.paragraphs, [])
        XCTAssertEqual(model.commandBanner, "Mira - new thought")
    }

    /// (b) "remember the milk Mira read that back to me" -> commits "remember the milk" AND fires
    /// readThatBack (speaks the just-committed pre-text).
    func testAccumulatingSegmentCommitsPreTextAndFiresReadThatBack() {
        let speaker = StubSpeaker()
        let model = makeModel(speaker: speaker)
        model.injectFinalized("remember the milk Mira read that back to me")
        XCTAssertEqual(model.paragraphs, ["remember the milk"])
        XCTAssertEqual(speaker.spoken, ["remember the milk"])
        XCTAssertEqual(model.commandBanner, "Mira - read that back")
    }

    /// (c) "here is my thought Mira flibber" (keyword + gibberish) -> commits the pre-text, drops the
    /// command tail, shows the chip.
    func testAccumulatingSegmentKeywordGibberishCommitsPreTextAndChips() {
        let model = makeModel()
        model.injectFinalized("here is my thought Mira flibber")
        XCTAssertEqual(model.paragraphs, ["here is my thought"], "pre-text is kept")
        XCTAssertEqual(model.commandBanner, "Sorry, I didn't catch that command")
    }

    /// (e) A custom control word is honored end-to-end through the view model: "Mira" is now ordinary
    /// text, and the configured word ("Nova") splits and fires.
    func testCustomControlWordHonoredThroughViewModel() {
        let model = DictationViewModel(
            service: StubCaptureService(),
            store: store,
            processor: MiraTextProcessor(controlWord: "Nova"),
            speaker: StubSpeaker(),
            controlWord: "Nova"
        )
        // "Mira" is no longer a control word: it is ordinary dictation.
        model.injectFinalized("Mira is a nice name")
        XCTAssertEqual(model.paragraphs, ["Mira is a nice name"])
        // "Nova" splits: commit the pre-text and remove it as the last paragraph.
        model.injectFinalized("keep this Nova remove the last paragraph")
        XCTAssertEqual(model.paragraphs, ["Mira is a nice name"],
                       "the Nova pre-text 'keep this' was committed then removed as the last paragraph")
        XCTAssertEqual(model.commandBanner, "Nova - removed last paragraph")
    }

    // MARK: - Keyword-led unrecognized command: dropped + chip (feedback 0005)

    func testKeywordLedUnrecognizedCommandIsDroppedAndChipped() {
        let model = makeModel()
        model.injectFinalized("Keep this one.")
        // Leads with the control word (no pre-text) but is not a known command: dropped, not
        // transcribed.
        model.injectFinalized("Mira do a barrel roll")
        XCTAssertEqual(model.paragraphs, ["Keep this one."], "keyword-led gibberish must not transcribe")
        XCTAssertEqual(model.commandBanner, "Sorry, I didn't catch that command")
    }

    /// The intentional tradeoff (feedback 0006): the control word switches the REST of the utterance
    /// to command mode, so a mid-sentence mention of the assistant's name commits the words before it
    /// and treats what follows as a command. Here "about the plan" is not a command, so the pre-text
    /// is kept and the tail is dropped with a chip.
    func testMidSentenceKeywordMentionSplitsAtKeyword() {
        let model = makeModel()
        model.injectFinalized("I told Mira about the plan")
        XCTAssertEqual(model.paragraphs, ["I told"], "the words before the control word are kept")
        XCTAssertEqual(model.commandBanner, "Sorry, I didn't catch that command")
    }

    // MARK: - No banner for a no-op command (no actual effect)

    func testNoOpRemoveOnEmptyThoughtShowsNoBanner() {
        let model = makeModel()
        model.injectFinalized("Mira remove the last paragraph")
        XCTAssertNil(model.commandBanner)
        model.injectFinalized("Mira remove the last sentence")
        XCTAssertNil(model.commandBanner)
    }

    func testNoOpReadBackOnEmptyThoughtShowsNoBanner() {
        let model = makeModel()
        model.injectFinalized("Mira read that back")
        XCTAssertNil(model.commandBanner)
    }

    func testNewThoughtOnEmptyThoughtShowsNoBanner() {
        let model = makeModel()
        model.injectFinalized("Mira new thought")
        XCTAssertNil(model.commandBanner)
    }

    // MARK: - New thought save failure: preserve content, surface error, no success banner

    func testNewThoughtSaveFailurePreservesContentAndSurfacesError() {
        let failing = ThrowingThoughtStore()
        let model = DictationViewModel(
            service: StubCaptureService(),
            store: failing,
            processor: MiraTextProcessor(),
            speaker: StubSpeaker()
        )
        model.injectFinalized("A thought that cannot be saved.")
        model.injectFinalized("Mira new thought")

        // Content is preserved (not bled into a fresh thought), the error is surfaced, and NO success
        // banner is shown.
        XCTAssertEqual(model.paragraphs, ["A thought that cannot be saved."])
        XCTAssertEqual(model.commandError, .newThoughtSaveFailed)
        XCTAssertNil(model.commandBanner)

        // A follow-up sentence appends to the SAME preserved thought, not a bled-together one.
        model.injectFinalized("Still the same thought.")
        XCTAssertEqual(model.paragraphs, [
            "A thought that cannot be saved.",
            "Still the same thought."
        ])
    }

    func testNewThoughtSaveSuccessResetsAndClearsError() {
        let model = makeModel()
        model.injectFinalized("A thought worth keeping.")
        model.injectFinalized("Mira new thought")
        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(model.paragraphs, [])
        XCTAssertNil(model.commandError)
        XCTAssertEqual(model.commandBanner, "Mira - new thought")
    }
}

// MARK: - Test doubles

/// A `ThoughtStoring` stub that records saves in memory and never fails. `@unchecked Sendable`: it is
/// only touched from the test's single actor, but `ThoughtStoring: Sendable` requires the annotation
/// for its mutable buffer.
private final class RecordingThoughtStore: ThoughtStoring, @unchecked Sendable {
    private(set) var saved: [Thought] = []

    @discardableResult
    func save(_ thought: Thought) throws -> URL {
        saved.append(thought)
        return URL(fileURLWithPath: "/dev/null")
    }

    func loadAll() -> [Thought] { saved }
    func delete(id: UUID) throws {
        saved.removeAll { $0.id == id }
    }
}

/// A `ThoughtStoring` stub whose `save` always throws, to exercise the "new thought" save-failure path.
private final class ThrowingThoughtStore: ThoughtStoring {
    struct SaveError: Error {}

    func save(_ thought: Thought) throws -> URL { throw SaveError() }
    func loadAll() -> [Thought] { [] }
    func delete(id: UUID) throws {}
}

/// A `Speaker` stub that records what was spoken and lets the test drive the finish callback.
@MainActor
private final class StubSpeaker: Speaker {
    var onFinish: (() -> Void)?
    private(set) var spoken: [String] = []

    func speak(_ text: String) {
        spoken.append(text)
    }

    func stop() {}

    /// Simulate the utterance finishing, as the production speaker's delegate would.
    func finish() {
        onFinish?()
    }
}

/// A `SpeechCaptureService` stub that counts lifecycle calls, so read-back's pause/resume can be
/// asserted without touching real audio.
@MainActor
private final class StubCaptureService: SpeechCaptureService {
    var onEvent: ((SpeechCaptureEvent) -> Void)?
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var recordingEnabled = false

    func requestAuthorization() async -> SpeechCaptureError? { nil }
    func availabilityError() -> SpeechCaptureError? { nil }
    func setRecordingEnabled(_ enabled: Bool) { recordingEnabled = enabled }
    func recordingURL() -> URL? { nil }
    func discardRecording() {}
    func start() {}
    func pause() { pauseCount += 1 }
    func resume() { resumeCount += 1 }
    func stop() {}
}
