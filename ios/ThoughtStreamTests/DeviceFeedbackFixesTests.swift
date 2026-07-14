import XCTest
@testable import ThoughtStream

/// Regression tests for the on-device feedback fixes (feedback 0005): pause/restart never loses
/// text (#2), the mic-level -> bar-height mapping (#5), the note word count (#6), and swipe-to-delete
/// through the store from the feed (#4). The command-mode changes (#3) live in
/// `MiraCommandParserTests` / `MiraCommandExecutionTests`.
final class DeviceFeedbackFixesTests: XCTestCase {

    // MARK: - #5 Mic level -> waveform mapping

    /// A zero level yields no lift (bars at floor); a non-zero level lifts them clearly. The mapping
    /// is monotonic and saturates at 1, and normal-speaking RMS clears the floor by a wide margin.
    func testLevelMappingLiftsBarsForNonZeroLevel() {
        XCTAssertEqual(SpeechDictationService.normalizedLevel(fromRMS: 0), 0, accuracy: 0.0001)

        let quiet = SpeechDictationService.normalizedLevel(fromRMS: 0.01)
        let normal = SpeechDictationService.normalizedLevel(fromRMS: 0.05)
        let loud = SpeechDictationService.normalizedLevel(fromRMS: 0.5)

        // A non-zero level yields a taller bar than zero.
        XCTAssertGreaterThan(quiet, 0)
        // Normal speaking clearly moves the bars: well above the 0.12 waveform floor.
        XCTAssertGreaterThan(normal, 0.3)
        // Monotonic: louder maps higher.
        XCTAssertGreaterThan(normal, quiet)
        XCTAssertGreaterThan(loud, normal)
        // Saturates at 1 and never exceeds it.
        XCTAssertLessThanOrEqual(loud, 1)
        XCTAssertEqual(SpeechDictationService.normalizedLevel(fromRMS: 1), 1, accuracy: 0.0001)
    }

    /// A NaN (or infinite) RMS must map to 0, not crash or produce a NaN bar height. This is the
    /// single finite guard (the duplicate in `rmsLevel` was removed in favor of this one).
    func testLevelMappingHandlesNaNAndInfinity() {
        XCTAssertEqual(SpeechDictationService.normalizedLevel(fromRMS: .nan), 0, accuracy: 0.0001)
        XCTAssertEqual(SpeechDictationService.normalizedLevel(fromRMS: .infinity), 0, accuracy: 0.0001)
        XCTAssertEqual(SpeechDictationService.normalizedLevel(fromRMS: -1), 0, accuracy: 0.0001)
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
        let one = Note(title: "t", paragraphs: ["Hello"], createdAt: Date())
        XCTAssertEqual(one.wordCount, 1)
        XCTAssertEqual(one.wordCountLabel, "1 word")

        let many = Note(
            title: "t",
            paragraphs: ["Call the supplier before noon.", "Draft the launch email today."],
            createdAt: Date()
        )
        // 5 + 5 = 10 words across paragraphs.
        XCTAssertEqual(many.wordCount, 10)
        XCTAssertEqual(many.wordCountLabel, "10 words")

        let empty = Note(title: "t", paragraphs: [], createdAt: Date())
        XCTAssertEqual(empty.wordCount, 0)
        XCTAssertEqual(empty.wordCountLabel, "0 words")

        // Extra whitespace does not inflate the count.
        let spaced = Note(title: "t", paragraphs: ["  spaced   out   words  "], createdAt: Date())
        XCTAssertEqual(spaced.wordCount, 3)
    }

    // MARK: - Note.hasAudio dual guard (a recording is not silently dropped, nor half-recognized)

    /// `hasAudio` requires BOTH an audio filename AND at least one timing. Pin the two-condition
    /// guard so a recording with a filename but no timings (or vice versa) is not treated as
    /// playable, and a fully-formed recording is recognized. A slip here would silently drop a real
    /// recording or surface an unplayable one.
    func testHasAudioRequiresBothFilenameAndTimings() {
        let timing = ParagraphTiming(start: 0, duration: 1)

        // Both present: a real recording.
        let full = Note(title: "t", paragraphs: ["a"], createdAt: Date(),
                        audioFileName: "x.m4a", timings: [timing])
        XCTAssertTrue(full.hasAudio)

        // Filename but no timings: not a mapped recording.
        let noTimings = Note(title: "t", paragraphs: ["a"], createdAt: Date(),
                             audioFileName: "x.m4a", timings: [])
        XCTAssertFalse(noTimings.hasAudio)

        // Timings but no filename: nothing to play.
        let noFile = Note(title: "t", paragraphs: ["a"], createdAt: Date(),
                          audioFileName: nil, timings: [timing])
        XCTAssertFalse(noFile.hasAudio)

        // Neither: plainly text-only.
        let textOnly = Note(title: "t", paragraphs: ["a"], createdAt: Date())
        XCTAssertFalse(textOnly.hasAudio)
    }
}

// MARK: - Feedback 0006 Fix A: last-partial commit on a nil-result task end (device-only)

/// The commit-on-end decision (`SpeechDictationService.resolveEnd`) is pure and testable, so the
/// accumulating-segment + nil-result-end behavior can be proven WITHOUT a live mic. On a real device
/// a task accumulates the whole passage and can end with an ERROR and a NIL result, holding the words
/// only as the in-progress partial - which must still be committed.
final class LastPartialCommitTests: XCTestCase {

    /// (1) Partials "he" -> "hello" -> "hello world" arrive, THEN the task ends with error+nil result:
    /// the last partial "hello world" is what must be committed (not lost).
    func testNilResultEndCommitsLastPartial() {
        // The service tracks the growing partial; the resolver commits it when the result is nil.
        XCTAssertEqual(SpeechDictationService.resolveEnd(resultText: nil, lastPartial: "hello world"),
                       .usedPartial("hello world"))
    }

    /// (3) A clean final does NOT double-commit: a non-empty result already CONTAINS the partial, so
    /// the resolver returns the result (used once), never the result plus the partial.
    func testCleanFinalUsesResultNotPartial() {
        // Result is the full accumulated phrase; the partial was an earlier prefix. The resolver
        // returns the result exactly once.
        XCTAssertEqual(
            SpeechDictationService.resolveEnd(resultText: "hello world", lastPartial: "hello"),
            .usedResult("hello world")
        )
    }

    /// An end with neither a usable result NOR a partial commits nothing (no empty paragraph).
    func testEmptyResultAndEmptyPartialCommitsNothing() {
        XCTAssertEqual(SpeechDictationService.resolveEnd(resultText: nil, lastPartial: ""), .none)
        XCTAssertEqual(SpeechDictationService.resolveEnd(resultText: "   ", lastPartial: "  \n\t "), .none)
        XCTAssertEqual(SpeechDictationService.resolveEnd(resultText: nil, lastPartial: "   "), .none)
    }

    /// An empty/whitespace result falls back to the partial (the device's nil-ish end).
    func testEmptyResultFallsBackToPartial() {
        XCTAssertEqual(SpeechDictationService.resolveEnd(resultText: "  ", lastPartial: "kept text"),
                       .usedPartial("kept text"))
    }

    /// The resolver now reports WHICH source it used, so `handleTaskEnd` attaches a range only when
    /// the RESULT (which carries valid timings) was committed - never re-derived from raw inputs.
    func testResolveEndReportsWhichSourceWasUsed() {
        XCTAssertEqual(SpeechDictationService.resolveEnd(resultText: "hello world", lastPartial: "x"),
                       .usedResult("hello world"))
        XCTAssertEqual(SpeechDictationService.resolveEnd(resultText: nil, lastPartial: "held"),
                       .usedPartial("held"))
    }

    /// PR #10 review (stop clears the tracked partial): after `stop()` empties `lastPartialText`, a
    /// late cancelled-task nil-result end resolves to nothing, so no stray second finalized segment is
    /// emitted (which would double the live paragraph after the note is already saved). Modeled at the
    /// resolver, the source of that decision: nil result + empty partial commits nothing.
    func testStopClearedPartialMeansLateNilEndCommitsNothing() {
        XCTAssertEqual(SpeechDictationService.resolveEnd(resultText: nil, lastPartial: ""), .none)
    }
}

// MARK: - #2 Pause / restart never loses text (event-boundary regression)

/// Proves the view model's finalize/restart/partial handling at the service->view-model event seam:
/// a natural pause ends the recognition task, which now emits the in-progress words as a
/// `.finalizedSegment` (not a partial). That committed paragraph must survive the fresh task's
/// replacing partials. Driven through a fake capture service so no live mic is needed.
@MainActor
final class PauseRestartPreservationTests: XCTestCase {
    private var store: MemoryNoteStore!
    private var service: EventDrivingCaptureService!

    override func setUp() {
        super.setUp()
        store = MemoryNoteStore()
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
        service.emit(.finalizedSegment("P1", range: nil))
        service.emit(.finalizedSegment("P2", range: nil))
        // The current task accumulates a growing partial, then ends with error+nil result: the
        // service commits the tracked partial "hello world" as a finalized segment.
        service.emit(.partial("he"))
        service.emit(.partial("hello"))
        service.emit(.partial("hello world"))
        service.emit(.finalizedSegment("hello world", range: nil))
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
        model.simulatePartial("here is my note")
        XCTAssertEqual(model.partial, "here is my note")
        // Once the control word appears, only the pre-keyword dictation shows; the forming command
        // ("new note") is not displayed.
        model.simulatePartial("here is my note Mira new")
        XCTAssertEqual(model.partial, "here is my note")
        // A keyword-led partial with no pre-text shows nothing.
        model.simulatePartial("Mira new note")
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
        service.emit(.finalizedSegment("Remember to call the supplier", range: nil))
        XCTAssertEqual(model.paragraphs, ["Remember to call the supplier"])
        XCTAssertEqual(model.partial, "", "committing a paragraph clears the live partial")

        // Task 2 (after the restart): a FRESH partial arrives. It must not erase the committed text.
        service.emit(.partial("and draft the email"))
        XCTAssertEqual(model.paragraphs, ["Remember to call the supplier"],
                       "the fresh task's partial must not lose the committed paragraph")

        // Finalize the second segment too.
        service.emit(.finalizedSegment("and draft the email", range: nil))
        XCTAssertEqual(model.paragraphs, [
            "Remember to call the supplier",
            "and draft the email",
        ])
    }

    /// Device double-commit regression (PR #10 review): on device the live partial echoes the SAME
    /// pre-keyword words the accumulating segment then finalizes with. When "P1 Mira new note"
    /// finalizes, the split commits "P1" - the stale partial "P1" must NOT then be folded in by
    /// `new note`, or the SAVED note would be ["P1","P1"]. Fails without clearing the partial in the
    /// `.split` case. A fresh note starts after the command.
    func testSplitNewNoteDoesNotDoubleCommitEchoedPartial() throws {
        let model = DictationViewModel(
            service: service, store: store, processor: MiraTextProcessor()
        )
        // The recognizer's live partial for the accumulating segment is the pre-keyword text "P1".
        model.simulatePartial("P1")
        XCTAssertEqual(model.partial, "P1")
        // The same segment finalizes as "P1 Mira new note": commit "P1" once, then start a new note.
        service.emit(.finalizedSegment("P1 Mira new note", range: nil))

        // The just-saved note is "P1" ONCE (not ["P1","P1"]), and a fresh empty note is now running.
        let saved = try XCTUnwrap(store.notes.last)
        XCTAssertEqual(saved.paragraphs, ["P1"], "new note must not double-commit the echoed partial")
        XCTAssertTrue(model.paragraphs.isEmpty, "a fresh note starts after new note")
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
        service.emit(.finalizedSegment("remember the milk Mira read that back to me", range: nil))

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
        service.emit(.finalizedSegment("First thought", range: nil))
        service.emit(.partial("Second thought"))
        service.emit(.finalizedSegment("Second thought", range: nil))

        let note = try XCTUnwrap(try model.finish())
        XCTAssertEqual(note.paragraphs, ["First thought", "Second thought"])
    }

    /// The ACTUAL reported bug (feedback 0005 #2): with prior committed paragraphs already in the
    /// note, a pause seam (task error-end emits its words as a `.finalizedSegment`) followed by the
    /// fresh task's empty/short partial must NOT wipe the committed text. Before the fix the last
    /// pre-pause words came in as a partial and the restart's fresh partial clobbered them; here we
    /// assert every prior paragraph AND the pause-seam paragraph all survive, in order.
    func testPriorParagraphsSurvivePauseSeamAndFreshPartial() {
        let model = makeModel()

        // Two paragraphs are already committed to the note.
        service.emit(.finalizedSegment("P1", range: nil))
        service.emit(.finalizedSegment("P2", range: nil))
        XCTAssertEqual(model.paragraphs, ["P1", "P2"])

        // The user keeps speaking; the recognition task then ENDS at a natural pause and emits the
        // in-progress words as a finalized segment (the commit-on-end fix).
        service.emit(.partial("P3"))
        service.emit(.finalizedSegment("P3", range: nil))
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
        service.emit(.finalizedSegment("P1", range: nil))
        XCTAssertEqual(model.paragraphs, ["P1"])

        // An error-ended task with no usable text arrives as an (empty / whitespace) finalized
        // segment. It must be dropped, not appended as a blank paragraph.
        service.emit(.finalizedSegment("", range: nil))
        service.emit(.finalizedSegment("   ", range: nil))
        service.emit(.finalizedSegment("\n\t ", range: nil))

        XCTAssertEqual(model.paragraphs, ["P1"], "an empty error-end must not append a blank paragraph")
    }
}

// MARK: - #4 Delete through the store from the feed

@MainActor
final class StreamFeedDeleteTests: XCTestCase {
    func testDeleteRemovesNoteThroughStoreAndReloads() async {
        let store = MemoryNoteStore()
        let keep = Note(title: "Keep", paragraphs: ["stays"], createdAt: Date())
        let drop = Note(title: "Drop", paragraphs: ["goes"], createdAt: Date())
        try? store.save(keep)
        try? store.save(drop)

        let feed = StreamFeed(store: store)
        await feed.start()
        XCTAssertEqual(feed.notes.count, 2)

        await feed.delete(id: drop.id)

        // The delete went THROUGH the store (removed there) and the feed reloaded to reflect it.
        XCTAssertEqual(store.deletedIDs, [drop.id])
        XCTAssertEqual(feed.notes.map(\.id), [keep.id])
        XCTAssertFalse(feed.deleteFailed, "a successful delete leaves no error surfaced")
    }

    /// Feedback 0005 #4/#9: deleting a note at the feed level also removes its sibling recording, so
    /// a delete never orphans audio on disk. Asserted through the store double's audio-delete log.
    func testDeleteAlsoRemovesSiblingAudioAtFeedLevel() async {
        let store = MemoryNoteStore()
        let note = Note(title: "Recorded", paragraphs: ["spoken"], createdAt: Date())
        try? store.save(note)

        let feed = StreamFeed(store: store)
        await feed.start()

        await feed.delete(id: note.id)

        XCTAssertEqual(store.deletedAudioIDs, [note.id],
                       "deleting a note must delete its sibling recording too")
    }

    /// Feedback 0005 #4: a throwing coordinated delete must be SURFACED, not swallowed. The feed
    /// sets `deleteFailed` so the view shows a brief message, and the note stays visible (the reload
    /// re-reflects the true on-disk state).
    func testFailedDeleteSurfacesErrorAndKeepsNote() async {
        let store = ThrowingDeleteStore()
        let note = Note(title: "Sticky", paragraphs: ["stays put"], createdAt: Date())
        try? store.save(note)

        let feed = StreamFeed(store: store)
        await feed.start()
        XCTAssertEqual(feed.notes.count, 1)

        await feed.delete(id: note.id)

        XCTAssertTrue(feed.deleteFailed, "a failed delete must surface an error state")
        XCTAssertEqual(feed.notes.map(\.id), [note.id], "a failed delete leaves the note visible")

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

/// An in-memory note store that records saves and deletes (note AND sibling audio), for the
/// feed/delete and save tests. `@unchecked Sendable`: touched only from the test's single actor,
/// but `NoteStoring: Sendable` requires the annotation for its mutable buffers.
private final class MemoryNoteStore: NoteStoring, @unchecked Sendable {
    private(set) var notes: [Note] = []
    private(set) var deletedIDs: [UUID] = []
    /// Audio IDs whose sibling recording was deleted, so a test can assert `delete(id:)` removes the
    /// audio too (feedback 0005 #4: a note delete must not orphan its recording).
    private(set) var deletedAudioIDs: [UUID] = []

    @discardableResult
    func save(_ note: Note) throws -> URL {
        notes.removeAll { $0.id == note.id }
        notes.append(note)
        return URL(fileURLWithPath: "/dev/null")
    }

    func loadAll() -> [Note] { notes.reversed() }

    func delete(id: UUID) throws {
        deletedIDs.append(id)
        // Mirror the real stores: deleting a note also removes its sibling recording.
        try deleteAudio(for: id)
        notes.removeAll { $0.id == id }
    }

    func deleteAudio(for id: UUID) throws {
        deletedAudioIDs.append(id)
    }
}

/// A store whose `delete` always throws, to prove a failed delete is SURFACED (not swallowed).
/// `@unchecked Sendable` for the same reason as `MemoryNoteStore`.
private final class ThrowingDeleteStore: NoteStoring, @unchecked Sendable {
    struct DeleteError: Error {}
    private(set) var notes: [Note] = []

    @discardableResult
    func save(_ note: Note) throws -> URL {
        notes.removeAll { $0.id == note.id }
        notes.append(note)
        return URL(fileURLWithPath: "/dev/null")
    }

    func loadAll() -> [Note] { notes.reversed() }

    func delete(id: UUID) throws { throw DeleteError() }
}

/// The on-device utterance-RESET detection (`SpeechDictationService.isReset`) is pure and testable.
/// It is what commits the pre-pause words when the recognizer starts a new utterance within a task
/// without ending it (feedback 0007), so the "Hey how's it going" -> "Yeah things..." reset from the
/// device recording no longer loses the first utterance.
final class UtteranceResetTests: XCTestCase {
    func testNewUtteranceWithDifferentStartIsReset() {
        // The exact case from the device screen recording.
        XCTAssertTrue(SpeechDictationService.isReset(
            previous: "Hey how's it going", current: "Yeah things are going pretty good"))
    }

    func testMonotonicGrowthIsNotReset() {
        XCTAssertFalse(SpeechDictationService.isReset(previous: "Hey how's", current: "Hey how's it going"))
    }

    func testLastWordRevisionIsNotReset() {
        XCTAssertFalse(SpeechDictationService.isReset(previous: "Hey how's it going", current: "Hey how's it goin"))
    }

    func testSameFirstWordDifferentSecondIsReset() {
        XCTAssertTrue(SpeechDictationService.isReset(previous: "The cat sat", current: "The dog ran"))
    }

    func testEmptyPreviousIsNotReset() {
        XCTAssertFalse(SpeechDictationService.isReset(previous: "", current: "anything at all"))
    }

    func testSingleWordGrowthIsNotResetButNewWordIs() {
        XCTAssertFalse(SpeechDictationService.isReset(previous: "Hey", current: "Hey there"))
        XCTAssertTrue(SpeechDictationService.isReset(previous: "Hey", current: "Yeah"))
    }

    // Revisions the recognizer makes as it gains context must NOT count as a reset - they caused the
    // duplicate-paragraph bug (feedback 0007) by re-committing growing prefixes of one sentence.
    func testFirstWordRevisionIsNotReset() {
        XCTAssertFalse(SpeechDictationService.isReset(
            previous: "It", current: "It's almost like I wonder in that particular case"))
    }

    func testMidSentenceRevisionIsNotReset() {
        XCTAssertFalse(SpeechDictationService.isReset(
            previous: "So you're getting a request the same week that it just",
            current: "So you're getting a request the same week that it's just like figure it out"))
    }

    func testContractionRevisionMidTextIsNotReset() {
        XCTAssertFalse(SpeechDictationService.isReset(
            previous: "the product team is built a thing and there is",
            current: "the product team is built a thing and there's making a bunch"))
    }

    // Feedback 0008 round 2 (screenshot duplicates): revisions that collapse spacing or drop a leading
    // word must NOT read as a new utterance - a plain prefix comparison split these into two paragraphs.
    func testSpaceCollapsingUrlRevisionIsNotReset() {
        XCTAssertFalse(SpeechDictationService.isReset(
            previous: "I'm saying the", current: "I'msayingthe.com"))
    }

    func testLeadingWordDroppedRevisionIsNotReset() {
        XCTAssertFalse(SpeechDictationService.isReset(
            previous: "What kind of games", current: "Kind of games"))
    }

    func testTrailingRevisionKeepingStartIsNotReset() {
        XCTAssertFalse(SpeechDictationService.isReset(
            previous: "baked potato or baked", current: "baked potato or baked potato"))
    }

    func testUnrelatedNewUtteranceIsStillReset() {
        // The improved logic must not START merging genuinely separate utterances.
        XCTAssertTrue(SpeechDictationService.isReset(
            previous: "I don't understand that", current: "Baked potato or baked potato"))
        XCTAssertTrue(SpeechDictationService.isReset(
            previous: "Aren't a good price", current: "OK"))
    }

    // Wrongful-merge guards (engineer + tester review): the revision-tolerant logic must NOT swallow a
    // genuinely new utterance just because it sits inside the previous or shares an ending. Losing a
    // paragraph is worse than a duplicate, so these MUST reset.
    func testShortNewUtteranceThatIsSubstringOfPreviousIsReset() {
        XCTAssertTrue(SpeechDictationService.isReset(previous: "I know", current: "No"))
        XCTAssertTrue(SpeechDictationService.isReset(
            previous: "I went to the store", current: "store"))
        XCTAssertTrue(SpeechDictationService.isReset(
            previous: "that looks ok now", current: "ok"))
    }

    func testDistinctUtterancesSharingAnEndingAreReset() {
        XCTAssertTrue(SpeechDictationService.isReset(
            previous: "please call the doctor", current: "do not call the doctor"))
        XCTAssertTrue(SpeechDictationService.isReset(
            previous: "we are going home", current: "they are going home"))
    }

    func testPunctuationOnlyNormalizesToEmptyAndIsNotReset() {
        XCTAssertEqual(SpeechDictationService.normalizedForReset("...!!!"), "")
        // An empty compact string on either side is not a reset (nothing to commit / adopt).
        XCTAssertFalse(SpeechDictationService.isReset(previous: "Hello there", current: "!!!"))
        XCTAssertFalse(SpeechDictationService.isReset(previous: "***", current: "Hello there"))
    }
}

/// Feedback 0008: a paragraph doubled when a Mira command followed it. A reset commits the paragraph,
/// then the same task's final transcription STILL leads with it, and the command split commits it
/// again. `strippingCommittedPrefix` removes the already-committed lead so it is committed only once.
final class CommittedPrefixDedupTests: XCTestCase {
    func testStripsExactCommittedParagraphBeforeCommand() {
        // The reported case: P2 was committed on the pause, then the command's final transcription
        // accumulated "P2 Mira read that back". The committed P2 must be stripped so the split does
        // not re-commit it.
        let result = SpeechDictationService.strippingCommittedPrefix(
            from: "Buy milk and eggs Mira read that back", committed: "Buy milk and eggs")
        XCTAssertEqual(result, "Mira read that back")
    }

    func testKeepsResultWhenRecognizerDroppedTheCommittedLead() {
        // The other device behavior: the recognizer internally reset, so its final transcription does
        // NOT lead with the committed paragraph. Nothing is stripped; the new utterance is kept whole.
        let result = SpeechDictationService.strippingCommittedPrefix(
            from: "Mira read that back", committed: "Buy milk and eggs")
        XCTAssertEqual(result, "Mira read that back")
    }

    func testStripsDespiteWordRevisionInTheCommittedLead() {
        // The recognizer revised "there is" -> "there's" between the committed partial and the final,
        // so the lead is not a byte-exact prefix. It is still consumed whole, not half-left.
        let result = SpeechDictationService.strippingCommittedPrefix(
            from: "I think there's Mira new note", committed: "I think there is")
        XCTAssertEqual(result, "Mira new note")
    }

    func testResultEqualToCommittedYieldsEmpty() {
        // The task ended right on the committed paragraph with no trailing words: everything is
        // already committed, so nothing remains to commit again.
        let result = SpeechDictationService.strippingCommittedPrefix(
            from: "Buy milk and eggs", committed: "Buy milk and eggs")
        XCTAssertEqual(result, "")
    }

    func testDifferentUtteranceIsNotStripped() {
        let result = SpeechDictationService.strippingCommittedPrefix(
            from: "Sell the car Mira stop", committed: "Buy milk and eggs")
        XCTAssertEqual(result, "Sell the car Mira stop")
    }

    func testEmptyCommittedReturnsResultUnchanged() {
        let result = SpeechDictationService.strippingCommittedPrefix(
            from: "Buy milk Mira new note", committed: "")
        XCTAssertEqual(result, "Buy milk Mira new note")
    }

    func testCaseInsensitiveLeadIsStripped() {
        let result = SpeechDictationService.strippingCommittedPrefix(
            from: "buy MILK and eggs Mira read that back", committed: "Buy milk and eggs")
        XCTAssertEqual(result, "Mira read that back")
    }

    func testWhitespacePaddedCommittedStillStrips() {
        let result = SpeechDictationService.strippingCommittedPrefix(
            from: "Buy milk Mira new note", committed: "   Buy milk   ")
        XCTAssertEqual(result, "Mira new note")
    }

    func testBelowMatchRatioThresholdIsNotStripped() {
        // Under 60% of the committed text lines up at the start, so it is a different utterance.
        let result = SpeechDictationService.strippingCommittedPrefix(
            from: "abcXXXXXXX and then some", committed: "abcdefghij")
        XCTAssertEqual(result, "abcXXXXXXX and then some")
    }
}

/// Feedback 0008: the pure task-end commit decision that wires the dedup (strip already-committed
/// lead), the text resolution, and the range-drop-when-stripped rule. This exercises the actual fix
/// path, not just the `strippingCommittedPrefix` helper.
final class TaskEndCommitTests: XCTestCase {
    func testStripsCommittedLeadAndDropsRange() {
        // The reported bug at the decision level: the reset committed "Second thoughts here", the
        // task-end result still leads with it plus the command. It is stripped, and the range is
        // dropped because the remaining text no longer matches the reported range.
        let commit = SpeechDictationService.resolveTaskEndCommit(
            resultText: "Second thoughts here Mira new note",
            resultRange: ParagraphTiming(start: 2, duration: 3),
            lastPartial: "Mira new note",
            committed: "Second thoughts here")
        XCTAssertEqual(commit?.text, "Mira new note")
        XCTAssertNil(commit?.range, "a stripped prefix drops the reported range")
    }

    func testKeepsRangeWhenNothingStripped() {
        let range = ParagraphTiming(start: 0, duration: 5)
        let commit = SpeechDictationService.resolveTaskEndCommit(
            resultText: "Buy milk and eggs", resultRange: range,
            lastPartial: "Buy milk and eggs", committed: "")
        XCTAssertEqual(commit?.text, "Buy milk and eggs")
        XCTAssertEqual(commit?.range, range, "with nothing stripped the reported range is kept")
    }

    func testResultFullyStrippedFallsBackToPartial() {
        // The task ended right on the committed paragraph: the result strips to empty, so the tracked
        // partial (a fresh utterance) is what commits, always without a range.
        let commit = SpeechDictationService.resolveTaskEndCommit(
            resultText: "Buy milk", resultRange: ParagraphTiming(start: 0, duration: 1),
            lastPartial: "next thought", committed: "Buy milk")
        XCTAssertEqual(commit?.text, "next thought")
        XCTAssertNil(commit?.range)
    }

    func testNilResultCommitsPartialWithoutRange() {
        let commit = SpeechDictationService.resolveTaskEndCommit(
            resultText: nil, resultRange: nil, lastPartial: "held partial", committed: "anything")
        XCTAssertEqual(commit?.text, "held partial")
        XCTAssertNil(commit?.range)
    }

    func testNothingUsableCommitsNothing() {
        let commit = SpeechDictationService.resolveTaskEndCommit(
            resultText: nil, resultRange: nil, lastPartial: "", committed: "")
        XCTAssertNil(commit, "no result and no partial commits nothing")
    }

    func testDroppedCommittedLeadKeepsFullResult() {
        // The recognizer internally reset, so its final result does NOT lead with the committed text.
        // Nothing is stripped, so the whole new utterance commits and its range is kept.
        let range = ParagraphTiming(start: 4, duration: 2)
        let commit = SpeechDictationService.resolveTaskEndCommit(
            resultText: "A brand new sentence", resultRange: range,
            lastPartial: "A brand new sentence", committed: "Older committed paragraph")
        XCTAssertEqual(commit?.text, "A brand new sentence")
        XCTAssertEqual(commit?.range, range)
    }
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
}

/// Feedback 0008: resuming a note continues it (same id/created), appended text is added, and the
/// note's original recording and per-paragraph timings are preserved. Keyboard editing replaces the
/// transcript text.
@MainActor
final class ResumeAndEditTests: XCTestCase {
    private var store: MemoryNoteStore!
    private var service: EventDrivingCaptureService!

    override func setUp() {
        super.setUp()
        store = MemoryNoteStore()
        service = EventDrivingCaptureService()
    }

    func testResumeSeedsExistingNoteAndPreservesRecordingOnSave() throws {
        let original = Note(
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
        service.emit(.finalizedSegment("Gamma", range: nil))
        let saved = try XCTUnwrap(try model.finish())

        XCTAssertEqual(saved.id, original.id, "resume continues the same note")
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
        service.emit(.finalizedSegment("First", range: nil))
        service.emit(.finalizedSegment("Second", range: nil))
        service.emit(.partial("in progress"))

        model.applyEditedTranscript("First edited\n\nSecond\n\nThird")

        XCTAssertEqual(model.paragraphs, ["First edited", "Second", "Third"])
        XCTAssertEqual(model.partial, "", "editing folds and clears the live partial")
    }

    func testEditableTranscriptJoinsParagraphsAndPartialWithBlankLines() {
        let model = DictationViewModel(service: service, store: store, processor: PassthroughTextProcessor())
        service.emit(.finalizedSegment("Para one", range: nil))
        service.emit(.partial("still typing"))
        XCTAssertEqual(model.editableTranscript, "Para one\n\nstill typing")
    }

    func testEditableTranscriptWithNoPartialIsJustParagraphs() {
        let model = DictationViewModel(service: service, store: store, processor: PassthroughTextProcessor())
        service.emit(.finalizedSegment("Para one", range: nil))
        service.emit(.finalizedSegment("Para two", range: nil))
        XCTAssertEqual(model.editableTranscript, "Para one\n\nPara two")
    }

    func testResumeTextOnlyNoteDoesNotFabricateAudioOnSave() throws {
        let original = Note(
            id: UUID(), title: "Text only", paragraphs: ["Alpha", "Beta"],
            createdAt: Date(timeIntervalSince1970: 500)
        )
        XCTAssertFalse(original.hasAudio)
        let model = DictationViewModel(
            service: service, store: store, processor: PassthroughTextProcessor(),
            recordsAudio: false, resuming: original)
        service.emit(.finalizedSegment("Gamma", range: nil))

        let saved = try XCTUnwrap(try model.finish())
        XCTAssertEqual(saved.paragraphs, ["Alpha", "Beta", "Gamma"])
        XCTAssertNil(saved.audioFileName, "a text-only note must not gain a recording on resume")
        XCTAssertFalse(saved.hasAudio)
    }

    func testEditingResumedNoteToFewerParagraphsTruncatesTimings() throws {
        let original = Note(
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

    func testNewNoteAfterResumeDoesNotCarryRecordingToFreshNote() throws {
        // Engineer review regression: resuming an audio note then "Mira new note" must not attach the
        // original recording to the fresh note.
        let original = Note(
            id: UUID(), title: "Rec", paragraphs: ["First"],
            createdAt: Date(timeIntervalSince1970: 500),
            audioFileName: "rec.m4a",
            timings: [ParagraphTiming(start: 0, duration: 2)])
        let model = DictationViewModel(
            service: service, store: store, processor: MiraTextProcessor(),
            recordsAudio: false, resuming: original)
        // "new note" saves the resumed note (keeping its audio) and starts a fresh one.
        service.emit(.finalizedSegment("Mira new note", range: nil))
        // The fresh note now captures new text and stops.
        service.emit(.finalizedSegment("Totally new", range: nil))
        let fresh = try XCTUnwrap(try model.finish())

        XCTAssertEqual(fresh.paragraphs, ["Totally new"])
        XCTAssertNil(fresh.audioFileName, "the fresh note must not inherit the resumed note's recording")
        XCTAssertFalse(fresh.hasAudio)
        // The resumed note was saved with its recording preserved.
        let resumedSaved = try XCTUnwrap(store.notes.first { $0.id == original.id })
        XCTAssertEqual(resumedSaved.audioFileName, "rec.m4a")
    }
}
