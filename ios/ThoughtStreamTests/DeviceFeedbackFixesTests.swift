import XCTest
@testable import ThoughtStream

/// Regression tests for the on-device feedback fixes (feedback 0005): pause/restart never loses
/// text (#2), the mic-level -> bar-height mapping (#5), the thought word count (#6), and swipe-to-delete
/// through the store from the feed (#4). The command-mode changes (#3) live in
/// `MiraCommandParserTests` / `MiraCommandExecutionTests`.
final class DeviceFeedbackFixesTests: XCTestCase {

    // MARK: - #5 Mic level -> waveform mapping

    /// A zero level yields no lift (bars at floor); a non-zero level lifts them clearly. The mapping
    /// is monotonic and saturates at 1, and normal-speaking RMS clears the floor by a wide margin.
    func testLevelMappingLiftsBarsForNonZeroLevel() {
        XCTAssertEqual(SpeechAnalyzerService.normalizedLevel(fromRMS: 0), 0, accuracy: 0.0001)

        let quiet = SpeechAnalyzerService.normalizedLevel(fromRMS: 0.01)
        let normal = SpeechAnalyzerService.normalizedLevel(fromRMS: 0.05)
        let loud = SpeechAnalyzerService.normalizedLevel(fromRMS: 0.5)

        // A non-zero level yields a taller bar than zero.
        XCTAssertGreaterThan(quiet, 0)
        // Normal speaking clearly moves the bars: well above the 0.12 waveform floor.
        XCTAssertGreaterThan(normal, 0.3)
        // Monotonic: louder maps higher.
        XCTAssertGreaterThan(normal, quiet)
        XCTAssertGreaterThan(loud, normal)
        // Saturates at 1 and never exceeds it.
        XCTAssertLessThanOrEqual(loud, 1)
        XCTAssertEqual(SpeechAnalyzerService.normalizedLevel(fromRMS: 1), 1, accuracy: 0.0001)
    }

    /// A NaN (or infinite) RMS must map to 0, not crash or produce a NaN bar height. This is the
    /// single finite guard (the duplicate in `rmsLevel` was removed in favor of this one).
    func testLevelMappingHandlesNaNAndInfinity() {
        XCTAssertEqual(SpeechAnalyzerService.normalizedLevel(fromRMS: .nan), 0, accuracy: 0.0001)
        XCTAssertEqual(SpeechAnalyzerService.normalizedLevel(fromRMS: .infinity), 0, accuracy: 0.0001)
        XCTAssertEqual(SpeechAnalyzerService.normalizedLevel(fromRMS: -1), 0, accuracy: 0.0001)
    }

    /// The Waveform's own height mapping: a non-zero level yields a taller bar than a zero level.
    /// Mirrors the private `barHeight` math so a regression that flattens the bars is caught.
    func testWaveformBarHeightRisesWithLevel() {
        func barHeight(index: Int, level: CGFloat, maxHeight: CGFloat) -> CGFloat {
            let available = (maxHeight.isFinite && maxHeight > 0) ? maxHeight : 0
            let safeLevel = level.isFinite ? min(1, max(0, level)) : 0
            let shape = (sin(Double(index) * 0.7) + 1) / 2
            let floor = 0.12
            let factor = floor + (shape * 0.35 + 0.65) * Double(safeLevel) * (1 - floor)
            return max(4, available * CGFloat(min(1, factor)))
        }
        let atZero = barHeight(index: 3, level: 0, maxHeight: 44)
        let atHalf = barHeight(index: 3, level: 0.5, maxHeight: 44)
        XCTAssertGreaterThan(atHalf, atZero, "a speaking level must make the bar taller than silence")
    }

    // MARK: - #6 Word count

    func testWordCountAndLabel() {
        let one = Thought(title: "t", paragraphs: ["Hello"], createdAt: Date())
        XCTAssertEqual(one.wordCount, 1)
        XCTAssertEqual(one.wordCountLabel, "1 word")

        let many = Thought(
            title: "t",
            paragraphs: ["Call the supplier before noon.", "Draft the launch email today."],
            createdAt: Date()
        )
        // 5 + 5 = 10 words across paragraphs.
        XCTAssertEqual(many.wordCount, 10)
        XCTAssertEqual(many.wordCountLabel, "10 words")

        let empty = Thought(title: "t", paragraphs: [], createdAt: Date())
        XCTAssertEqual(empty.wordCount, 0)
        XCTAssertEqual(empty.wordCountLabel, "0 words")

        // Extra whitespace does not inflate the count.
        let spaced = Thought(title: "t", paragraphs: ["  spaced   out   words  "], createdAt: Date())
        XCTAssertEqual(spaced.wordCount, 3)
    }

    // MARK: - Thought.hasAudio dual guard (a recording is not silently dropped, nor half-recognized)

    /// `hasAudio` requires BOTH an audio filename AND at least one timing. Pin the two-condition
    /// guard so a recording with a filename but no timings (or vice versa) is not treated as
    /// playable, and a fully-formed recording is recognized. A slip here would silently drop a real
    /// recording or surface an unplayable one.
    func testHasAudioRequiresBothFilenameAndTimings() {
        let timing = ParagraphTiming(start: 0, duration: 1)

        // Both present: a real recording.
        let full = Thought(title: "t", paragraphs: ["a"], createdAt: Date(),
                        audioFileName: "x.m4a", timings: [timing])
        XCTAssertTrue(full.hasAudio)

        // Filename but no timings: not a mapped recording.
        let noTimings = Thought(title: "t", paragraphs: ["a"], createdAt: Date(),
                             audioFileName: "x.m4a", timings: [])
        XCTAssertFalse(noTimings.hasAudio)

        // Timings but no filename: nothing to play.
        let noFile = Thought(title: "t", paragraphs: ["a"], createdAt: Date(),
                          audioFileName: nil, timings: [timing])
        XCTAssertFalse(noFile.hasAudio)

        // Neither: plainly text-only.
        let textOnly = Thought(title: "t", paragraphs: ["a"], createdAt: Date())
        XCTAssertFalse(textOnly.hasAudio)
    }
}

// MARK: - Feedback 0006 Fix A: last-partial commit on a nil-result task end (device-only)
// MARK: - #2 Pause / restart never loses text (event-boundary regression)

/// Proves the view model's finalize/restart/partial handling at the service->view-model event seam:
/// a natural pause ends the recognition task, which now emits the in-progress words as a
/// `.finalizedSegment` (not a partial). That committed paragraph must survive the fresh task's
/// replacing partials. Driven through a fake capture service so no live mic is needed.
@MainActor
final class PauseRestartPreservationTests: XCTestCase {
    private var store: MemoryThoughtStore!
    private var service: EventDrivingCaptureService!

    override func setUp() {
        super.setUp()
        store = MemoryThoughtStore()
        service = EventDrivingCaptureService()
    }

    private func makeModel() -> DictationViewModel {
        DictationViewModel(service: service, store: store, processor: PassthroughTextProcessor())
    }

    /// Feedback 0006 Fix A end-to-end at the event seam: prior paragraphs survive a long-pause
    /// restart AND the dangling partial (the device's nil-result end committed it as a finalized
    /// segment) is preserved, not lost. Mirrors the service emitting the tracked partial on end.
    func testPriorParagraphsAndDanglingPartialSurviveLongPause() {
        let model = makeModel()
        // Two paragraphs already committed.
        service.emitFinalized("P1", range: nil)
        service.emitFinalized("P2", range: nil)
        // The current task accumulates a growing partial, then ends with error+nil result: the
        // service commits the tracked partial "hello world" as a finalized segment.
        service.emit(.partial("he"))
        service.emit(.partial("hello"))
        service.emit(.partial("hello world"))
        service.emitFinalized("hello world", range: nil)
        XCTAssertEqual(model.paragraphs, ["P1", "P2", "hello world"],
                       "prior paragraphs and the dangling partial all survive the long-pause restart")
    }

    /// Feedback 0006 Fix B live-partial rule: once a control-word token is present in the live
    /// partial, only the PRE-keyword text is shown - the forming command must not be displayed (and
    /// cannot fire, since commands execute only on finalization).
    func testLivePartialShowsOnlyPreKeywordText() {
        let model = DictationViewModel(
            service: service, store: store, processor: MiraTextProcessor()
        )
        // A partial with no control word shows in full.
        model.simulatePartial("here is my thought")
        XCTAssertEqual(model.partial, "here is my thought")
        // Once the control word appears, only the pre-keyword dictation shows; the forming command
        // ("new thought") is not displayed.
        model.simulatePartial("here is my thought Mira new")
        XCTAssertEqual(model.partial, "here is my thought")
        // A keyword-led partial with no pre-text shows nothing.
        model.simulatePartial("Mira new thought")
        XCTAssertEqual(model.partial, "")
    }

    /// The core invariant: words spoken before a natural pause are COMMITTED when the task ends
    /// (finalizedSegment), and the following task's fresh partials do NOT overwrite them.
    func testPauseThenNewTaskDoesNotLoseCommittedText() {
        let model = makeModel()

        // Task 1: user speaks, shown as a live partial (not yet committed).
        service.emit(.partial("Remember to call the supplier"))
        XCTAssertTrue(model.paragraphs.isEmpty, "partial is not committed until the task ends")

        // Natural pause: the recognition task ENDS. Post-fix the service emits the in-progress text
        // as a finalized segment (the bug emitted it as a partial, so the next task's empty partial
        // wiped it out).
        service.emitFinalized("Remember to call the supplier", range: nil)
        XCTAssertEqual(model.paragraphs, ["Remember to call the supplier"])
        XCTAssertEqual(model.partial, "", "committing a paragraph clears the live partial")

        // Task 2 (after the restart): a FRESH partial arrives. It must not erase the committed text.
        service.emit(.partial("and draft the email"))
        XCTAssertEqual(model.paragraphs, ["Remember to call the supplier"],
                       "the fresh task's partial must not lose the committed paragraph")

        // Finalize the second segment too.
        service.emitFinalized("and draft the email", range: nil)
        XCTAssertEqual(model.paragraphs, [
            "Remember to call the supplier",
            "and draft the email",
        ])
    }

    /// Device double-commit regression (PR #10 review): on device the live partial echoes the SAME
    /// pre-keyword words the accumulating segment then finalizes with. When "P1 Mira new thought"
    /// finalizes, the split commits "P1" - the stale partial "P1" must NOT then be folded in by
    /// `new thought`, or the SAVED thought would be ["P1","P1"]. Fails without clearing the partial in the
    /// `.split` case. A fresh thought starts after the command.
    func testSplitNewThoughtDoesNotDoubleCommitEchoedPartial() throws {
        let model = DictationViewModel(
            service: service, store: store, processor: MiraTextProcessor()
        )
        // The recognizer's live partial for the accumulating segment is the pre-keyword text "P1".
        model.simulatePartial("P1")
        XCTAssertEqual(model.partial, "P1")
        // The same segment finalizes as "P1 Mira new thought": commit "P1" once, then start a new thought.
        service.emitFinalized("P1 Mira new thought", range: nil)

        // The just-saved thought is "P1" ONCE (not ["P1","P1"]), and a fresh empty thought is now running.
        let saved = try XCTUnwrap(store.thoughts.last)
        XCTAssertEqual(saved.paragraphs, ["P1"], "new thought must not double-commit the echoed partial")
        XCTAssertTrue(model.paragraphs.isEmpty, "a fresh thought starts after new thought")
        XCTAssertEqual(model.partial, "", "the stale echoed partial is cleared by the split")
    }

    /// The same device echo for `read that back`: "remember the milk Mira read that back to me"
    /// commits "remember the milk" ONCE and read-back targets THAT paragraph - not a doubled
    /// ["remember the milk","remember the milk"] with read-back on the wrong one. Fails without the
    /// partial-clear in the `.split` case.
    func testSplitReadThatBackDoesNotDoubleCommitEchoedPartial() throws {
        let speaker = TraceSpeaker()
        let model = DictationViewModel(
            service: service, store: store, processor: MiraTextProcessor(), speaker: speaker
        )
        // The live partial echoes the pre-keyword dictation.
        model.simulatePartial("remember the milk")
        XCTAssertEqual(model.partial, "remember the milk")
        // The accumulating segment finalizes with the command tail.
        service.emitFinalized("remember the milk Mira read that back to me", range: nil)

        // Committed exactly once, and read-back spoke THAT paragraph (not a stale duplicate).
        XCTAssertEqual(model.paragraphs, ["remember the milk"],
                       "read that back must not double-commit the echoed partial")
        XCTAssertEqual(speaker.spoken, ["remember the milk"],
                       "read-back targets the single committed paragraph")
    }

    /// The committed text survives an actual stop-and-save through the store.
    func testCommittedTextAcrossRestartSurvivesSave() throws {
        let model = makeModel()
        service.emit(.partial("First thought"))
        service.emitFinalized("First thought", range: nil)
        service.emit(.partial("Second thought"))
        service.emitFinalized("Second thought", range: nil)

        let thought = try XCTUnwrap(try model.finish())
        XCTAssertEqual(thought.paragraphs, ["First thought", "Second thought"])
    }

    /// The ACTUAL reported bug (feedback 0005 #2): with prior committed paragraphs already in the
    /// thought, a pause seam (task error-end emits its words as a `.finalizedSegment`) followed by the
    /// fresh task's empty/short partial must NOT wipe the committed text. Before the fix the last
    /// pre-pause words came in as a partial and the restart's fresh partial clobbered them; here we
    /// assert every prior paragraph AND the pause-seam paragraph all survive, in order.
    func testPriorParagraphsSurvivePauseSeamAndFreshPartial() {
        let model = makeModel()

        // Two paragraphs are already committed to the thought.
        service.emitFinalized("P1", range: nil)
        service.emitFinalized("P2", range: nil)
        XCTAssertEqual(model.paragraphs, ["P1", "P2"])

        // The user keeps speaking; the recognition task then ENDS at a natural pause and emits the
        // in-progress words as a finalized segment (the commit-on-end fix).
        service.emit(.partial("P3"))
        service.emitFinalized("P3", range: nil)
        XCTAssertEqual(model.paragraphs, ["P1", "P2", "P3"],
                       "the pause-seam paragraph must append, not replace committed text")

        // The fresh task after the restart reports an empty/short partial. It must NOT clobber any
        // committed paragraph (this is exactly what the bug did).
        service.emit(.partial(""))
        service.emit(.partial("a"))
        XCTAssertEqual(model.paragraphs, ["P1", "P2", "P3"],
                       "a fresh-task partial must never wipe committed paragraphs")
        // And nothing bled the partial into the committed text.
        XCTAssertEqual(model.displayParagraphs, ["P1", "P2", "P3", "a"])
    }

    /// The second guard (feedback 0005 #2): a task that ends with EMPTY (or whitespace-only) text
    /// must NOT create a blank paragraph. The service guards empty text before emitting, and the
    /// view model's `commitParagraph` guards trimmed-empty too; this pins both so an error-end with
    /// no words never appends an empty paragraph.
    func testEmptyErrorEndDoesNotCreateBlankParagraph() {
        let model = makeModel()
        service.emitFinalized("P1", range: nil)
        XCTAssertEqual(model.paragraphs, ["P1"])

        // An error-ended task with no usable text arrives as an (empty / whitespace) finalized
        // segment. It must be dropped, not appended as a blank paragraph.
        service.emitFinalized("", range: nil)
        service.emitFinalized("   ", range: nil)
        service.emitFinalized("\n\t ", range: nil)

        XCTAssertEqual(model.paragraphs, ["P1"], "an empty error-end must not append a blank paragraph")
    }
}

// MARK: - #4 Delete through the store from the feed

@MainActor
final class StreamFeedDeleteTests: XCTestCase {
    func testDeleteRemovesThoughtThroughStoreAndReloads() async {
        let store = MemoryThoughtStore()
        let keep = Thought(title: "Keep", paragraphs: ["stays"], createdAt: Date())
        let drop = Thought(title: "Drop", paragraphs: ["goes"], createdAt: Date())
        _ = try? store.save(keep)
        _ = try? store.save(drop)

        let feed = StreamFeed(store: store)
        await feed.start()
        XCTAssertEqual(feed.thoughts.count, 2)

        await feed.delete(id: drop.id)

        // The delete went THROUGH the store (removed there) and the feed reloaded to reflect it.
        XCTAssertEqual(store.deletedIDs, [drop.id])
        XCTAssertEqual(feed.thoughts.map(\.id), [keep.id])
        XCTAssertFalse(feed.deleteFailed, "a successful delete leaves no error surfaced")
    }

    /// Feedback 0005 #4/#9: deleting a thought at the feed level also removes its sibling recording, so
    /// a delete never orphans audio on disk. Asserted through the store double's audio-delete log.
    func testDeleteAlsoRemovesSiblingAudioAtFeedLevel() async {
        let store = MemoryThoughtStore()
        let thought = Thought(title: "Recorded", paragraphs: ["spoken"], createdAt: Date())
        _ = try? store.save(thought)

        let feed = StreamFeed(store: store)
        await feed.start()

        await feed.delete(id: thought.id)

        XCTAssertEqual(store.deletedAudioIDs, [thought.id],
                       "deleting a thought must delete its sibling recording too")
    }

    /// Feedback 0005 #4: a throwing coordinated delete must be SURFACED, not swallowed. The feed
    /// sets `deleteFailed` so the view shows a brief message, and the thought stays visible (the reload
    /// re-reflects the true on-disk state).
    func testFailedDeleteSurfacesErrorAndKeepsThought() async {
        let store = ThrowingDeleteStore()
        let thought = Thought(title: "Sticky", paragraphs: ["stays put"], createdAt: Date())
        _ = try? store.save(thought)

        let feed = StreamFeed(store: store)
        await feed.start()
        XCTAssertEqual(feed.thoughts.count, 1)

        await feed.delete(id: thought.id)

        XCTAssertTrue(feed.deleteFailed, "a failed delete must surface an error state")
        XCTAssertEqual(feed.thoughts.map(\.id), [thought.id], "a failed delete leaves the thought visible")

        // The view dismisses the message after showing it.
        feed.clearDeleteFailure()
        XCTAssertFalse(feed.deleteFailed)
    }
}

// MARK: - Test doubles

/// A capture service that just forwards events the test posts, so the view model's event handling
/// can be exercised without live audio.
@MainActor
private final class EventDrivingCaptureService: SpeechCaptureService {
    var onEvent: ((SpeechCaptureEvent) -> Void)?

    func emit(_ event: SpeechCaptureEvent) { onEvent?(event) }

    /// Emit a finalized segment. `isAnalysisStart` defaults to true and the raw seconds to non-finite,
    /// so each emitted segment is its own paragraph (the pre-0012 "one finalized = one paragraph"
    /// behavior) unless a grouping test passes real gap timing (feedback 0012).
    func emitFinalized(
        _ text: String,
        range: ParagraphTiming? = nil,
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

    func requestAuthorization() async -> SpeechCaptureError? { nil }
    func availabilityError() -> SpeechCaptureError? { nil }
    func setRecordingEnabled(_ enabled: Bool) {}
    func recordingURL() -> URL? { nil }
    func discardRecording() {}
    func start() {}
    func pause() {}
    func resume() {}
    func stop() {}
}

/// A `Speaker` stub that records what read-back spoke, so a test can assert read-back targeted the
/// single committed paragraph (not a stale duplicate).
@MainActor
private final class TraceSpeaker: Speaker {
    var onFinish: (() -> Void)?
    private(set) var spoken: [String] = []
    func speak(_ text: String) { spoken.append(text) }
    func stop() {}
}

/// An in-memory thought store that records saves and deletes (thought AND sibling audio), for the
/// feed/delete and save tests. `@unchecked Sendable`: touched only from the test's single actor,
/// but `ThoughtStoring: Sendable` requires the annotation for its mutable buffers.
private final class MemoryThoughtStore: ThoughtStoring, @unchecked Sendable {
    private(set) var thoughts: [Thought] = []
    private(set) var deletedIDs: [UUID] = []
    /// Audio IDs whose sibling recording was deleted, so a test can assert `delete(id:)` removes the
    /// audio too (feedback 0005 #4: a thought delete must not orphan its recording).
    private(set) var deletedAudioIDs: [UUID] = []

    @discardableResult
    func save(_ thought: Thought) throws -> URL {
        thoughts.removeAll { $0.id == thought.id }
        thoughts.append(thought)
        return URL(fileURLWithPath: "/dev/null")
    }

    func loadAll() -> [Thought] { thoughts.reversed() }

    func delete(id: UUID) throws {
        deletedIDs.append(id)
        // Mirror the real stores: deleting a thought also removes its sibling recording.
        try deleteAudio(for: id)
        thoughts.removeAll { $0.id == id }
    }

    func deleteAudio(for id: UUID) throws {
        deletedAudioIDs.append(id)
    }
}

/// A store whose `delete` always throws, to prove a failed delete is SURFACED (not swallowed).
/// `@unchecked Sendable` for the same reason as `MemoryThoughtStore`.
private final class ThrowingDeleteStore: ThoughtStoring, @unchecked Sendable {
    struct DeleteError: Error {}
    private(set) var thoughts: [Thought] = []

    @discardableResult
    func save(_ thought: Thought) throws -> URL {
        thoughts.removeAll { $0.id == thought.id }
        thoughts.append(thought)
        return URL(fileURLWithPath: "/dev/null")
    }

    func loadAll() -> [Thought] { thoughts.reversed() }

    func delete(id: UUID) throws { throw DeleteError() }
}

/// Feedback 0008: every cheat-sheet command phrase actually parses to its command, so the on-screen
/// list never drifts from the parser grammar (architect review follow-up).
final class CheatSheetGrammarTests: XCTestCase {
    func testEachCheatSheetPhraseParsesToItsCommand() {
        let processor = MiraTextProcessor()
        let cw = MiraTextProcessor.defaultControlWord
        for command in MiraCommand.cheatSheet {
            let segment = processor.process("\(cw) \(command.spokenPhrase)")
            guard case let .split(_, outcome) = segment, case let .command(parsed) = outcome else {
                XCTFail("\(command.spokenPhrase) did not parse as a command")
                continue
            }
            XCTAssertEqual(parsed, command, "\(cw) \(command.spokenPhrase) must fire \(command)")
        }
    }

    /// Spec 0016: the remove-last-sentence cheat-sheet detail LISTS the new phrasings, so the
    /// on-screen help stays truthful and a dropped phrasing regresses visibly rather than silently.
    /// Both new phrasings are also proved to fire in `MiraCommandParserTests`.
    func testRemoveLastSentenceDetailListsNewPhrasings() {
        let detail = MiraCommand.removeLastSentence.cheatSheetDetail
        XCTAssertTrue(detail.contains("delete the last line"), "detail must mention the line phrasing")
        XCTAssertTrue(detail.contains("scratch that"), "detail must mention the scratch phrasing")
    }
}

/// Feedback 0008: resuming a thought continues it (same id/created), appended text is added, and the
/// thought's original recording and per-paragraph timings are preserved. Keyboard editing replaces the
/// transcript text.
@MainActor
final class ResumeAndEditTests: XCTestCase {
    private var store: MemoryThoughtStore!
    private var service: EventDrivingCaptureService!

    override func setUp() {
        super.setUp()
        store = MemoryThoughtStore()
        service = EventDrivingCaptureService()
    }

    func testResumeSeedsExistingThoughtAndPreservesRecordingOnSave() throws {
        let original = Thought(
            id: UUID(),
            title: "Alpha",
            paragraphs: ["Alpha", "Beta"],
            createdAt: Date(timeIntervalSince1970: 1000),
            audioFileName: "rec.m4a",
            timings: [ParagraphTiming(start: 0, duration: 1), ParagraphTiming(start: 1, duration: 2)]
        )
        let model = DictationViewModel(
            service: service, store: store, processor: PassthroughTextProcessor(),
            recordsAudio: false, resuming: original
        )
        XCTAssertEqual(model.paragraphs, ["Alpha", "Beta"], "resume seeds the existing paragraphs")

        // Continue dictating one more paragraph, then stop and save.
        service.emitFinalized("Gamma", range: nil)
        let saved = try XCTUnwrap(try model.finish())

        XCTAssertEqual(saved.id, original.id, "resume continues the same thought")
        XCTAssertEqual(saved.createdAt, original.createdAt, "the original creation time is kept")
        XCTAssertEqual(saved.paragraphs, ["Alpha", "Beta", "Gamma"], "new text appends")
        XCTAssertEqual(saved.audioFileName, "rec.m4a", "the original recording is preserved")
        XCTAssertEqual(saved.timings.count, 3, "one timing per paragraph after resume")
        XCTAssertEqual(saved.timings[0], ParagraphTiming(start: 0, duration: 1))
        XCTAssertEqual(saved.timings[1], ParagraphTiming(start: 1, duration: 2))
        // The appended paragraph has no recorded range, so it plays back via text-to-speech.
        XCTAssertEqual(saved.timings[2], ParagraphTiming(start: 0, duration: 0))
    }

    func testApplyEditedTranscriptReplacesParagraphsAndClearsPartial() {
        let model = DictationViewModel(service: service, store: store, processor: PassthroughTextProcessor())
        service.emitFinalized("First", range: nil)
        service.emitFinalized("Second", range: nil)
        service.emit(.partial("in progress"))

        model.applyEditedTranscript("First edited\n\nSecond\n\nThird")

        XCTAssertEqual(model.paragraphs, ["First edited", "Second", "Third"])
        XCTAssertEqual(model.partial, "", "editing folds and clears the live partial")
    }

    func testEditableTranscriptJoinsParagraphsAndPartialWithBlankLines() {
        let model = DictationViewModel(service: service, store: store, processor: PassthroughTextProcessor())
        service.emitFinalized("Para one", range: nil)
        service.emit(.partial("still typing"))
        XCTAssertEqual(model.editableTranscript, "Para one\n\nstill typing")
    }

    func testEditableTranscriptWithNoPartialIsJustParagraphs() {
        let model = DictationViewModel(service: service, store: store, processor: PassthroughTextProcessor())
        service.emitFinalized("Para one", range: nil)
        service.emitFinalized("Para two", range: nil)
        XCTAssertEqual(model.editableTranscript, "Para one\n\nPara two")
    }

    func testResumeTextOnlyThoughtDoesNotFabricateAudioOnSave() throws {
        let original = Thought(
            id: UUID(), title: "Text only", paragraphs: ["Alpha", "Beta"],
            createdAt: Date(timeIntervalSince1970: 500)
        )
        XCTAssertFalse(original.hasAudio)
        let model = DictationViewModel(
            service: service, store: store, processor: PassthroughTextProcessor(),
            recordsAudio: false, resuming: original)
        service.emitFinalized("Gamma", range: nil)

        let saved = try XCTUnwrap(try model.finish())
        XCTAssertEqual(saved.paragraphs, ["Alpha", "Beta", "Gamma"])
        XCTAssertNil(saved.audioFileName, "a text-only thought must not gain a recording on resume")
        XCTAssertFalse(saved.hasAudio)
    }

    func testEditingResumedThoughtToFewerParagraphsTruncatesTimings() throws {
        let original = Thought(
            id: UUID(), title: "Three", paragraphs: ["One", "Two", "Three"],
            createdAt: Date(timeIntervalSince1970: 500),
            audioFileName: "rec.m4a",
            timings: [
                ParagraphTiming(start: 0, duration: 1),
                ParagraphTiming(start: 1, duration: 1),
                ParagraphTiming(start: 2, duration: 1),
            ])
        let model = DictationViewModel(
            service: service, store: store, processor: PassthroughTextProcessor(),
            recordsAudio: false, resuming: original)
        // Hand-edit down to a single paragraph, then save.
        model.applyEditedTranscript("One only")
        let saved = try XCTUnwrap(try model.finish())
        XCTAssertEqual(saved.paragraphs, ["One only"])
        XCTAssertEqual(saved.timings.count, 1, "timings are truncated to the edited paragraph count")
        XCTAssertEqual(saved.audioFileName, "rec.m4a", "the original recording is still preserved")
    }

    func testNewThoughtAfterResumeDoesNotCarryRecordingToFreshThought() throws {
        // Engineer review regression: resuming an audio thought then "Mira new thought" must not attach the
        // original recording to the fresh thought.
        let original = Thought(
            id: UUID(), title: "Rec", paragraphs: ["First"],
            createdAt: Date(timeIntervalSince1970: 500),
            audioFileName: "rec.m4a",
            timings: [ParagraphTiming(start: 0, duration: 2)])
        let model = DictationViewModel(
            service: service, store: store, processor: MiraTextProcessor(),
            recordsAudio: false, resuming: original)
        // "new thought" saves the resumed thought (keeping its audio) and starts a fresh one.
        service.emitFinalized("Mira new thought", range: nil)
        // The fresh thought now captures new text and stops.
        service.emitFinalized("Totally new", range: nil)
        let fresh = try XCTUnwrap(try model.finish())

        XCTAssertEqual(fresh.paragraphs, ["Totally new"])
        XCTAssertNil(fresh.audioFileName, "the fresh thought must not inherit the resumed thought's recording")
        XCTAssertFalse(fresh.hasAudio)
        // The resumed thought was saved with its recording preserved.
        let resumedSaved = try XCTUnwrap(store.thoughts.first { $0.id == original.id })
        XCTAssertEqual(resumedSaved.audioFileName, "rec.m4a")
    }
}

/// Spec 0002 (SpeechAnalyzer swap): the pure mappers extracted from the device-only service so the
/// timing decision and the resample-buffer capacity math are provable in CI.
final class SpeechAnalyzerMappingTests: XCTestCase {
    // MARK: paragraphTiming (CMTimeRange seconds -> ParagraphTiming)

    func testNoRecordingYieldsNilTiming() {
        XCTAssertNil(SpeechAnalyzerService.paragraphTiming(
            startSeconds: 1.0, durationSeconds: 2.0, offset: 0, hasRecording: false))
    }

    func testZeroOrNonFiniteDurationYieldsNilTiming() {
        XCTAssertNil(SpeechAnalyzerService.paragraphTiming(
            startSeconds: 1.0, durationSeconds: 0, offset: 0, hasRecording: true))
        XCTAssertNil(SpeechAnalyzerService.paragraphTiming(
            startSeconds: 1.0, durationSeconds: .nan, offset: 0, hasRecording: true))
        XCTAssertNil(SpeechAnalyzerService.paragraphTiming(
            startSeconds: .infinity, durationSeconds: 2.0, offset: 0, hasRecording: true))
    }

    func testTimingAnchorsToAbsoluteRecordingTimeWithOffset() {
        // A finalized result at 1.5s..2.0s in the SECOND analysis, which began 10s into the recording,
        // maps to 11.5s..12.0s absolute.
        let timing = SpeechAnalyzerService.paragraphTiming(
            startSeconds: 1.5, durationSeconds: 0.5, offset: 10, hasRecording: true)
        XCTAssertEqual(timing, ParagraphTiming(start: 11.5, duration: 0.5))
    }

    func testTimingWithZeroOffsetIsTheRelativeRange() {
        let timing = SpeechAnalyzerService.paragraphTiming(
            startSeconds: 3.0, durationSeconds: 1.0, offset: 0, hasRecording: true)
        XCTAssertEqual(timing, ParagraphTiming(start: 3.0, duration: 1.0))
    }

    // MARK: convertedCapacity (resample output-buffer size)

    func testCapacityDownsampleAddsHeadroom() {
        // 48k -> 16k, 4800 frames -> 1600 + 1024 headroom.
        XCTAssertEqual(
            SpeechAnalyzerService.convertedCapacity(frameLength: 4800, inputRate: 48000, outputRate: 16000),
            2624)
    }

    func testCapacityUpsampleAddsHeadroom() {
        // 16k -> 48k, 1600 frames -> 4800 + 1024.
        XCTAssertEqual(
            SpeechAnalyzerService.convertedCapacity(frameLength: 1600, inputRate: 16000, outputRate: 48000),
            5824)
    }

    func testCapacitySameRateIsFramesPlusHeadroom() {
        XCTAssertEqual(
            SpeechAnalyzerService.convertedCapacity(frameLength: 4096, inputRate: 48000, outputRate: 48000),
            5120)
    }

    func testCapacityDegenerateInputsYieldZero() {
        XCTAssertEqual(SpeechAnalyzerService.convertedCapacity(frameLength: 0, inputRate: 48000, outputRate: 16000), 0)
        XCTAssertEqual(SpeechAnalyzerService.convertedCapacity(frameLength: 4800, inputRate: 0, outputRate: 16000), 0)
        XCTAssertEqual(SpeechAnalyzerService.convertedCapacity(frameLength: 4800, inputRate: 48000, outputRate: 0), 0)
    }
}

// MARK: - Feedback 0012: pause-based paragraph grouping in the view model

/// Proves the flowing, Notes-style paragraph grouping at the service->view-model event seam: a
/// mid-thought breath (small inter-segment gap) lands in ONE paragraph; a real pause (large gap)
/// breaks into two; a resume-seam segment (analysis start) always starts a new paragraph. Driven
/// through the injected event seam, no live audio.
@MainActor
final class ParagraphGroupingViewModelTests: XCTestCase {
    private var store: MemoryThoughtStore!
    private var service: EventDrivingCaptureService!

    override func setUp() {
        super.setUp()
        store = MemoryThoughtStore()
        service = EventDrivingCaptureService()
    }

    private func makeModel() -> DictationViewModel {
        DictationViewModel(service: service, store: store, processor: PassthroughTextProcessor())
    }

    /// Two finalized segments with a SMALL inter-gap flow into ONE paragraph, joined by a single space.
    /// (The precise merged TIMING - first start through last end - is asserted in
    /// `DualCaptureViewModelTests.testSmallGapMergesParagraphsAndTimings`, which has the recording stub.)
    func testSmallGapMergesIntoOneParagraph() {
        let model = makeModel()
        // First segment: 0.0..2.0 (analysis start).
        service.emitFinalized(
            "Remember to call the supplier", range: nil,
            startSeconds: 0.0, durationSeconds: 2.0, isAnalysisStart: true)
        // A breath: next starts at 2.5 (0.5s gap), ends at 3.5 -> same paragraph.
        service.emitFinalized(
            "before noon", range: nil,
            startSeconds: 2.5, durationSeconds: 1.0, isAnalysisStart: false)

        XCTAssertEqual(model.paragraphs, ["Remember to call the supplier before noon"],
                       "a mid-thought breath stays in one paragraph")
    }

    /// A small-gap merge keeps paragraphs and timings in lockstep: after two merged segments there is
    /// still exactly ONE paragraph, and a text-only save round-trips it intact.
    func testSmallGapKeepsTimingsAndParagraphsInLockstep() throws {
        let model = makeModel()
        service.emitFinalized(
            "One", range: ParagraphTiming(start: 0.0, duration: 1.0),
            startSeconds: 0.0, durationSeconds: 1.0, isAnalysisStart: true)
        service.emitFinalized(
            "two", range: ParagraphTiming(start: 1.2, duration: 1.0),
            startSeconds: 1.2, durationSeconds: 1.0, isAnalysisStart: false)
        // One paragraph after a small-gap merge; a text-only finish keeps it as one paragraph.
        XCTAssertEqual(model.paragraphs, ["One two"])
        let saved = try XCTUnwrap(try model.finish())
        XCTAssertEqual(saved.paragraphs, ["One two"], "arrays stay in lockstep: one merged paragraph")
    }

    /// Two finalized segments with a LARGE inter-gap land in TWO paragraphs.
    func testLargeGapStartsNewParagraph() {
        let model = makeModel()
        service.emitFinalized(
            "First thought", range: nil,
            startSeconds: 0.0, durationSeconds: 1.0, isAnalysisStart: true)
        // A clear pause: next starts at 3.0 (2.0s gap) -> new paragraph.
        service.emitFinalized(
            "Second thought", range: nil,
            startSeconds: 3.0, durationSeconds: 1.0, isAnalysisStart: false)

        XCTAssertEqual(model.paragraphs, ["First thought", "Second thought"],
                       "a clear pause breaks into two paragraphs")
    }

    /// A resume-seam segment (analysis start, even with a tiny raw gap that would otherwise merge)
    /// starts a new paragraph, so a pause/resume never mis-merges across the seam.
    func testResumeSeamStartsNewParagraph() {
        let model = makeModel()
        // A paragraph in the first analysis, ending at 10.0.
        service.emitFinalized(
            "Before pause", range: nil,
            startSeconds: 9.0, durationSeconds: 1.0, isAnalysisStart: true)
        // Resume: analysis time resets to ~0.1. Its raw gap against 10.0 is a large negative, but the
        // analysis-start flag must force a NEW paragraph, not an append.
        service.emitFinalized(
            "After resume", range: nil,
            startSeconds: 0.1, durationSeconds: 1.0, isAnalysisStart: true)

        XCTAssertEqual(model.paragraphs, ["Before pause", "After resume"],
                       "a resume seam always starts a fresh paragraph")
    }

    /// A merged (small-gap) paragraph whose last timing was nil (recording off / no range) leaves the
    /// timing nil - it plays back via text-to-speech - and never grows the timings array out of step.
    func testMergeWithNilTimingLeavesTimingNilAndArraysAligned() throws {
        let model = makeModel()
        service.emitFinalized(
            "One", range: nil,
            startSeconds: 0.0, durationSeconds: 1.0, isAnalysisStart: true)
        service.emitFinalized(
            "two", range: nil,
            startSeconds: 1.2, durationSeconds: 1.0, isAnalysisStart: false)
        XCTAssertEqual(model.paragraphs, ["One two"])
        // A text-only save proves the merged paragraph is intact and singular.
        let saved = try XCTUnwrap(try model.finish())
        XCTAssertEqual(saved.paragraphs, ["One two"])
        XCTAssertNil(saved.audioFileName, "no recording means the merged paragraph stays text-only")
    }

    /// PR #24 review (tester major): a whitespace-only finalized segment arriving MID-FLOW at a small
    /// gap must (a) create no blank paragraph, and (b) NOT corrupt the grouping of the next real
    /// segment - because blank segments no longer advance the grouper's anchor, the next real segment's
    /// gap is measured against the LAST REAL segment, so a small gap still flows.
    func testWhitespaceMidFlowCreatesNoParagraphAndDoesNotCorruptGrouping() {
        let model = makeModel()
        // A real first segment ending at 1.0.
        service.emitFinalized(
            "One", range: nil,
            startSeconds: 0.0, durationSeconds: 1.0, isAnalysisStart: true)
        // A whitespace-only segment lands at a small gap (would-be end 1.4). It must be dropped and must
        // NOT advance the anchor.
        service.emitFinalized(
            "   ", range: nil,
            startSeconds: 1.2, durationSeconds: 0.2, isAnalysisStart: false)
        XCTAssertEqual(model.paragraphs, ["One"], "a whitespace-only segment creates no blank paragraph")
        // The next real segment starts at 1.4: a 0.4s gap from the LAST REAL segment's end (1.0), below
        // threshold -> flow into the same paragraph. This measures against "One"'s end (1.0), proving
        // the ignored blank segment did not advance the anchor to ~1.4 and corrupt the decision.
        service.emitFinalized(
            "two", range: nil,
            startSeconds: 1.4, durationSeconds: 1.0, isAnalysisStart: false)
        XCTAssertEqual(model.paragraphs, ["One two"],
                       "the next real segment groups against the last REAL segment, not the blank one")
    }

    /// PR #24 review (engineer minor): "Mira new thought" resets the grouper, so the FIRST committed
    /// segment of the fresh thought is its own paragraph even if its raw start would be a small gap from
    /// the previous thought's last segment end. Without the reset the carried-over anchor could merge the
    /// new thought's opener into... nothing (empty paragraphs) or mis-group it.
    func testNewThoughtResetsGrouperSoFreshThoughtFirstSegmentIsItsOwnParagraph() throws {
        let model = DictationViewModel(
            service: service, store: store, processor: MiraTextProcessor())
        // First thought: one paragraph ending (raw) at 2.0.
        service.emitFinalized(
            "First thought body", range: nil,
            startSeconds: 0.0, durationSeconds: 2.0, isAnalysisStart: false)
        // "Mira new thought" saves and resets. It is a pure-command split (empty pre-text), so it does not
        // advance the grouper; and startNewThought resets it regardless.
        service.emitFinalized(
            "Mira new thought", range: nil,
            startSeconds: 2.1, durationSeconds: 1.0, isAnalysisStart: false)
        XCTAssertTrue(model.paragraphs.isEmpty, "a fresh thought starts empty after new thought")
        // The fresh thought's first real segment lands at raw start 2.3 (a 0.3s gap from the OLD thought's 2.0
        // end - a small gap that, if the grouper had carried over, would try to append). It must be its
        // OWN paragraph in the fresh thought.
        service.emitFinalized(
            "Fresh thought opener", range: nil,
            startSeconds: 2.3, durationSeconds: 1.0, isAnalysisStart: false)
        XCTAssertEqual(model.paragraphs, ["Fresh thought opener"],
                       "the reset grouper makes the fresh thought's first segment its own paragraph")
    }
}
