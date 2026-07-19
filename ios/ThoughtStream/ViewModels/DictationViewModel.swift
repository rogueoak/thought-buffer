import Foundation
import SwiftUI

/// Drives the dictation screen: holds the growing thought, the live partial phrase, the mic level,
/// and the capture phase, and coordinates the speech service and the thought store.
@MainActor
final class DictationViewModel: ObservableObject {
    /// Where capture is in its lifecycle, which the view uses to pick its content and controls.
    enum Phase: Equatable {
        case idle          // not yet started (requesting permission)
        case recording
        case paused
        case readingBack   // capture is paused while Mira speaks a paragraph aloud
        case denied(DeniedReason)
        case saved
    }

    /// A view-model-owned reason capture was denied or could not start, mapped from the capture
    /// service's error so the service's error type never leaks into the view layer. Carries the
    /// user-facing copy directly, so views render text without knowing service internals.
    enum DeniedReason: Equatable {
        case speechNotAuthorized
        case microphoneNotAuthorized
        case onDeviceUnavailable
        case recognizerUnavailable
        case engineFailure

        init(_ error: SpeechCaptureError) {
            switch error {
            case .speechNotAuthorized: self = .speechNotAuthorized
            case .microphoneNotAuthorized: self = .microphoneNotAuthorized
            case .onDeviceUnavailable: self = .onDeviceUnavailable
            case .recognizerUnavailable: self = .recognizerUnavailable
            // The raw error string is intentionally dropped: user-facing copy is static.
            case .engineFailure: self = .engineFailure
            }
        }

        /// Short, user-facing headline for the denied state.
        var headline: String {
            switch self {
            case .speechNotAuthorized:
                return "Speech access is off"
            case .microphoneNotAuthorized:
                return "Microphone access is off"
            case .onDeviceUnavailable:
                return "On-device speech is not ready"
            case .recognizerUnavailable:
                return "Speech is unavailable"
            case .engineFailure:
                return "Could not start recording"
            }
        }

        /// A sentence or two telling the user what to do next. Static copy only: no raw error
        /// text is surfaced, so nothing internal leaks into user-facing strings.
        var detail: String {
            switch self {
            case .speechNotAuthorized:
                return "Thought Stream needs speech recognition to turn your voice into thoughts. "
                    + "Turn it on in Settings, under Thought Stream."
            case .microphoneNotAuthorized:
                return "Thought Stream needs the microphone to hear you. Turn it on in Settings, "
                    + "under Thought Stream."
            case .onDeviceUnavailable:
                return "Your device has not finished preparing on-device speech for this language. "
                    + "Add the language in Settings, then try again."
            case .recognizerUnavailable:
                return "Speech recognition is not available on this device right now. Try again "
                    + "in a moment."
            case .engineFailure:
                return "Something went wrong starting the recorder. Please try again."
            }
        }
    }

    /// A command that just fired, shown as a transient chip and then cleared. Nil most of the time.
    enum CommandBanner: Equatable {
        case removedLastSentence
        case removedLastParagraph
        case newThought
        case readThatBack

        init(_ command: MiraCommand) {
            switch command {
            case .removeLastSentence: self = .removedLastSentence
            case .removeLastParagraph: self = .removedLastParagraph
            case .newThought: self = .newThought
            case .readThatBack: self = .readThatBack
            }
        }

        /// The effect portion of the chip label, e.g. "removed last sentence". `showBanner`
        /// prepends the control word so the whole chip reads "Mira - removed last sentence".
        var label: String {
            switch self {
            case .removedLastSentence: return "removed last sentence"
            case .removedLastParagraph: return "removed last paragraph"
            case .newThought: return "new thought"
            case .readThatBack: return "read that back"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    /// Finalized paragraphs committed to the thought so far.
    @Published private(set) var paragraphs: [String] = []
    /// The in-progress phrase for the current task, shown live with a caret.
    @Published private(set) var partial: String = ""
    /// Smoothed microphone level, 0...1, for the waveform.
    @Published private(set) var level: Float = 0
    /// The most recent command chip label, or nil. Set when a command has an actual effect,
    /// cleared after a moment. Assembled here (where the active control word is known) so the view
    /// renders a plain string and stays correct when Settings makes the control word configurable.
    @Published private(set) var commandBanner: String?
    /// Set when a voice command (currently "Mira new thought") fails to save, so the view surfaces an
    /// error rather than the success chip. The current content is preserved on screen.
    @Published private(set) var commandError: CommandError?

    /// A voice command that could not complete, surfaced to the view instead of a success chip.
    enum CommandError: Equatable {
        /// "Mira new thought" could not save the current thought; its content is preserved on screen.
        case newThoughtSaveFailed
    }

    private let service: SpeechCaptureService
    private let store: ThoughtStoring
    private let processor: TextProcessor
    private let speaker: Speaker
    /// Whether to record the session's audio (spec 0007). Read from settings at construction so it
    /// applies to this session; `transcriptOnly` never opens the file writer.
    private let recordsAudio: Bool
    /// Joins a newly-recorded resume segment onto a thought's existing recording (feedback 0022), or nil
    /// when a session records no new audio onto an existing recording (a fresh session, a text-only
    /// append, or tests that do not exercise the join). When present AND the resumed thought already had
    /// audio AND a new segment was captured, `finish()` schedules an OFF-main concatenation that combines
    /// the original + new audio into one file, offsets the new paragraphs' timings past the original, and
    /// re-saves. On ANY concatenation failure the original recording is kept and the new paragraphs stay
    /// text-only (the pre-0022 behavior), so the original is never lost.
    private let audioConcatenator: AudioConcatenating?
    /// The active control word, used to assemble the command chip label (e.g. "Mira - new thought") and
    /// shown on the cheat sheet (feedback 0008). Injected so it stays in sync with the processor's
    /// control word once Settings makes it configurable, keeping the chip prefix out of the view.
    let controlWord: String
    private var createdAt = Date()
    private var thoughtID = UUID()
    /// The folder the thought is saved into (spec 0010). A fresh session is created at the TOP LEVEL
    /// (empty) - thoughts are filed into folders afterward via PR B's move action. A RESUMED thought keeps
    /// the folder it already lives in, so continuing it re-saves it in place rather than yanking it
    /// back to the root. Reset to top level when "new thought" starts a fresh thought mid-session.
    private var folderPath: [String] = []

    /// A user-set title carried over when RESUMING a thought (spec 0009). A fresh session always
    /// auto-derives its title, but resuming a thought the user titled must keep that title rather than
    /// re-deriving it from the (now longer) body. Nil / false for a fresh session.
    private var hasCustomTitle = false
    private var customTitle: String?

    /// The recording filename carried over when RESUMING an existing thought (feedback 0008): the thought
    /// keeps its original recording. Nil for a fresh session, where any recording comes from the live
    /// capture instead. Feedback 0022: when recording is on, a resume also captures a NEW segment that is
    /// CONCATENATED onto this original off-main after `finish()` - so the original is preserved either way.
    private var existingAudioFileName: String?

    /// The number of paragraphs seeded from the resumed thought (feedback 0022), i.e. how many leading
    /// paragraphs pre-date the resume. New paragraphs are appended after these; the count is the boundary
    /// `RecordingTiming.offsetResumedTimings` uses to shift only the newly-recorded paragraphs past the
    /// existing audio on the concatenated timeline. Zero for a fresh session. (The offset seconds come from
    /// the concatenator's measured existing-duration, not the timings, so no duration is cached here.)
    private var existingParagraphCount = 0

    /// One timing per committed paragraph, in lockstep with `paragraphs` (spec 0007). A finalized
    /// segment appends its range here as its text is committed; a paragraph committed without a range
    /// (a command-folded partial, or recording off) appends a nil placeholder so the arrays stay
    /// aligned. Trailing nils are trimmed when the thought is built.
    private var paragraphTimings: [ParagraphTiming?] = []

    /// Decides whether a finalized segment flows into the current paragraph or starts a new one, by the
    /// silence gap between segments (feedback 0012). All the policy lives in the pure grouper; the view
    /// model only routes on its decision. Its anchor spans one THOUGHT's dictation and is RESET at a thought
    /// boundary (`resetForNewThought`, called from `startNewThought`) so the gap never carries over from the
    /// previous thought's last segment into the fresh thought's first; a pause/resume seam within a thought is
    /// handled by the service's analysis-start flag.
    private var grouper = ParagraphGrouper()

    /// How long the command chip stays up before auto-dismissing.
    private let bannerDuration: Duration = .seconds(2)
    private var bannerTask: Task<Void, Never>?

    /// True while Mira reads a paragraph aloud and capture is paused for it, so `readBackDidFinish`
    /// restores capture only when read-back was the thing that paused it (never keyed off `phase`,
    /// which the user can change by tapping Pause mid-playback).
    private var isReadingBack = false
    /// Whether capture was recording when read-back began, so it resumes to the right state (back
    /// to recording, or staying paused if the user tapped Pause during playback).
    private var wasRecordingBeforeReadBack = false

    init(
        service: SpeechCaptureService? = nil,
        store: ThoughtStoring,
        processor: TextProcessor = PassthroughTextProcessor(),
        speaker: Speaker? = nil,
        recordsAudio: Bool = false,
        audioConcatenator: AudioConcatenating? = nil,
        controlWord: String = MiraTextProcessor.defaultControlWord,
        folderPath: [String] = [],
        resuming: Thought? = nil
    ) {
        // Build the production service here (on the main actor) when none is injected, so the
        // service's main-actor-isolated initializer is not called from a nonisolated default.
        self.service = service ?? SpeechAnalyzerService()
        self.store = store
        self.processor = processor
        self.speaker = speaker ?? SystemSpeaker()
        self.recordsAudio = recordsAudio
        self.audioConcatenator = audioConcatenator
        self.controlWord = controlWord
        // A brand-new session started while browsing a folder files its thought THERE, not at the root
        // (feedback: the record + new-thought actions must be contextual). A resuming thought overrides this
        // below with the folder it already lives in.
        self.folderPath = folderPath
        // Resuming an existing thought (feedback 0008): keep its id, creation time, and text so the
        // session continues that thought (saving overwrites the same file) rather than starting a new one.
        // The original recording and its per-paragraph timings are preserved for the existing paragraphs.
        //
        // Feedback 0022 (supersedes feedback 0008's "a resumed session records no new audio"): when
        // recording is on, a resume DOES capture a new audio segment. New paragraphs still commit their
        // (new-segment-relative) timings; after `finish()` the new segment is CONCATENATED onto the
        // original recording off-main and the new timings are offset past the original so playback seeks
        // correctly across the seam. `existingParagraphCount` anchors that offset (its seconds come from
        // the concatenator's measured existing-duration). On any concatenation failure the original
        // recording is kept and the new paragraphs stay text-only, exactly the pre-0022 behavior (the
        // words are never lost, the original never lost).
        if let resuming {
            thoughtID = resuming.id
            createdAt = resuming.createdAt
            paragraphs = resuming.paragraphs
            paragraphTimings = Self.seedTimings(for: resuming)
            existingAudioFileName = resuming.audioFileName
            existingParagraphCount = resuming.paragraphs.count
            // Keep the resumed thought in the folder it already lives in, so continuing it re-saves in
            // place rather than relocating it to the top level. Overrides the `folderPath` argument (a
            // resume ignores any browsing-context path). `self.` because the init parameter shadows it.
            self.folderPath = resuming.folderPath
            // Keep a user-set title through the resume (spec 0009); a derived title re-derives normally.
            if resuming.hasCustomTitle {
                hasCustomTitle = true
                customTitle = resuming.title
            }
        }
        // Tell the capture service whether to tee audio to a file for this session, before it starts.
        self.service.setRecordingEnabled(recordsAudio)
        self.service.onEvent = { [weak self] event in
            self?.handle(event)
        }
        self.speaker.onFinish = { [weak self] in
            self?.readBackDidFinish()
        }
    }

    /// The per-paragraph timing slots to seed when resuming a thought, aligned 1:1 with its paragraphs:
    /// each paragraph keeps its recorded range (or nil when the thought had no timing for it), so the
    /// preserved recording still maps to the original paragraphs after resume.
    private static func seedTimings(for thought: Thought) -> [ParagraphTiming?] {
        thought.paragraphs.indices.map { thought.timing(forParagraphAt: $0) }
    }

    /// The full transcript so far, including the live partial, for display.
    var displayParagraphs: [String] {
        var all = paragraphs
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            all.append(trimmed)
        }
        return all
    }

    /// True when there is nothing captured yet (used for placeholder copy).
    var isEmpty: Bool {
        paragraphs.isEmpty && partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the dock should offer a live waveform (recording only).
    var isRecording: Bool { phase == .recording }

    // MARK: - Lifecycle

    /// Request permission, then begin capturing. Call once when the screen appears.
    func begin() async {
        if let authError = await service.requestAuthorization() {
            phase = .denied(DeniedReason(authError))
            return
        }
        if let availError = service.availabilityError() {
            phase = .denied(DeniedReason(availError))
            return
        }
        phase = .recording
        service.start()
    }

    /// Toggle pause / resume.
    func togglePause() {
        switch phase {
        case .recording:
            service.pause()
            level = 0
            phase = .paused
        case .paused:
            phase = .recording
            service.resume()
        case .readingBack:
            // The user tapped Pause while Mira was reading a paragraph aloud. Capture is already
            // torn down for playback, so just record the intent: when read-back finishes it stays
            // paused instead of resuming. This keeps the session honest and never stuck.
            wasRecordingBeforeReadBack = false
            phase = .paused
        default:
            break
        }
    }

    /// Stop capture and save the thought. Returns the saved thought, or nil if nothing was captured.
    /// Throws if the store fails to persist the thought, so the caller can surface the failure
    /// instead of silently reporting success.
    @discardableResult
    func finish() throws -> Thought? {
        service.stop()
        speaker.stop()
        // Fold any live partial into the committed paragraphs before saving. The partial is
        // already processed (see `handle`/`simulatePartial`), so append it directly rather than
        // running it through the processor a second time.
        foldPartialIntoParagraphs()
        level = 0

        guard !paragraphs.isEmpty else {
            // Nothing to save: drop any (empty) recording so no orphan temp file lingers.
            discardPendingRecording()
            phase = .saved
            return nil
        }

        // The session's recording (finalized by `service.stop()` above) belongs to this final thought.
        let thought = try saveCurrentThought(adoptingRecording: true)

        // Resume-continues-audio (feedback 0022): a resumed thought that ALREADY had a recording and
        // captured a NEW segment this session. `saveCurrentThought` kept the ORIGINAL recording (the safe
        // fallback); now MOVE the new segment out of the service's temp slot to its own file and schedule
        // the off-main concatenation. Grab it BEFORE `discardPendingRecording()` (which would delete it).
        // The concat task OWNS the moved file's cleanup. Falls back to keeping the original (text-only
        // append) when there is no concatenator, no existing recording, no new segment, or on any failure.
        let resumeSegmentURL = takeResumeSegmentForConcatenation(savedThought: thought)

        // A successful adopt MOVES the temp file into storage; if adopting was skipped or failed, a
        // temp file may linger. Clean it up so no orphan recording is left on disk. (When a resume segment
        // was taken above it is already moved out, so this discards whatever - if anything - remains.)
        discardPendingRecording()
        phase = .saved
        // Resume-continues-audio (feedback 0022): if a resume captured a new segment onto an existing
        // recording, join it on OFF the main actor. `finish()` returns immediately with the thought saved
        // against its ORIGINAL recording; the concatenation re-saves in the background. (There is no
        // longer any dead-air trim here - that feature was removed in capture-pipeline feedback 0026.)
        if let resumeSegmentURL {
            // Capture the REAL committed timings now (the new paragraphs carry their new-segment-relative
            // ranges, before the fallback save zeroed them on disk). The concatenation task offsets THESE
            // past the existing recording - the on-disk fallback timings are placeholders it must not read.
            scheduleResumeConcatenation(
                for: thought, newSegmentURL: resumeSegmentURL, committedTimings: resolvedTimings())
        }
        return thought
    }

    /// Move the newly-recorded resume segment out of the capture service's temp slot to its own file for
    /// the off-main concatenation (feedback 0022), or nil when this session does not join audio onto an
    /// existing recording. Non-nil only when there is a concatenator, the resumed thought already had a
    /// recording (`existingAudioFileName`), recording is on, and the service produced a new segment. The
    /// move takes ownership from the service so the immediately-following `discardPendingRecording()` does
    /// not delete it; the concatenation task cleans it up.
    private func takeResumeSegmentForConcatenation(savedThought: Thought) -> URL? {
        guard audioConcatenator != nil,
              existingAudioFileName != nil,
              recordsAudio,
              savedThought.hasAudio,
              let segmentURL = service.recordingURL() else { return nil }
        let fm = FileManager.default
        let owned = fm.temporaryDirectory
            .appendingPathComponent("thoughtstream-resume-\(UUID().uuidString).\(ThoughtStore.audioFileExtension)")
        do {
            try? fm.removeItem(at: owned)
            try fm.moveItem(at: segmentURL, to: owned)
            return owned
        } catch {
            // Could not take ownership: leave the segment for `discardPendingRecording` and keep the
            // original recording (text-only append), the safe fallback.
            return nil
        }
    }

    /// Called on the main actor after a background audio re-save lands and the host should reload its feed
    /// to drop the stale in-memory thought: a resume concatenation (feedback 0022, joined audio + offset
    /// timings). Nil when no host wired it (tests, screenshot tooling). Set by the view.
    ///
    /// KNOWN LIMITATION (feedback 0017): this reloads the LIST feed, but an ALREADY-OPEN `ThoughtDetailView`
    /// pushed on the stack keeps its own stale thought snapshot until it is popped and reopened. Harmless
    /// today because detail playback is whole-file: a resume concatenation only EXTENDS the recording (the
    /// pre-existing portion still plays whole from time 0), so a stale per-paragraph timing is never
    /// consulted. A future PER-PARAGRAPH SEEK feature MUST revisit this - it would seek against timings that
    /// no longer match the re-saved audio - by refreshing the open detail's thought here (or re-reading it
    /// at seek time).
    var onBackgroundAudioResave: (() -> Void)?

    /// Join a resume's newly-recorded segment onto the thought's existing recording OFF the main actor,
    /// then adopt the combined audio and offset the new paragraphs' timings past the original (feedback
    /// 0022). Non-blocking: `finish()` has already returned the thought saved with its ORIGINAL recording
    /// and the new paragraphs as text-only (the safe fallback). On ANY failure the fallback stands - the
    /// original recording is kept, the new paragraphs stay text-only - so the original is never lost.
    ///
    /// Sequence. First, concatenate original + new segment into one file via the thin AVFoundation seam.
    /// Second, re-read the thought FRESH and confirm it still exists before swapping audio (a
    /// soft-delete/move during the join must not orphan a raw-voice copy), then swap through the COORDINATED
    /// `replaceAudio` (never a bare replace, so iCloud is not raced), and only on a real replace offset the
    /// new timings by the combined file's measured existing-duration and re-save the FRESH thought
    /// (preserving a concurrent edit). Every temp is cleaned up on every exit. (The new segment is joined
    /// AS CAPTURED - the dead-air trim that once tightened it first was removed in capture-pipeline
    /// feedback 0026, so there is no per-segment remap step anymore.)
    private func scheduleResumeConcatenation(
        for thought: Thought,
        newSegmentURL: URL,
        committedTimings: [ParagraphTiming]
    ) {
        guard let audioConcatenator,
              let existingURL = store.audioURL(for: thought.id) else {
            try? FileManager.default.removeItem(at: newSegmentURL)
            return
        }
        let store = self.store
        let thoughtID = thought.id
        let existingParagraphCount = self.existingParagraphCount
        Task.detached { [weak self] in
            let fm = FileManager.default
            // Clean up every temp we create/own on any exit from here on.
            var tempsToClean: [URL] = [newSegmentURL]
            defer { for url in tempsToClean { try? fm.removeItem(at: url) } }

            // 1. Concatenate original + new segment into one combined file (both inputs untouched). Any
            //    failure (unreadable, empty new segment, incompatible format) leaves the fallback standing.
            guard case .concatenated(let combinedURL, let existingDuration) =
                    await audioConcatenator.concatenate(existing: existingURL, new: newSegmentURL) else { return }
            tempsToClean.append(combinedURL)

            // 2. Re-read the thought FRESH and confirm it still exists BEFORE touching any audio. If it was
            //    soft-deleted/moved during the join, bail - never adopt (which would orphan a copy of the
            //    just-deleted recording); the temps are cleaned by the defer.
            guard let current = store.loadAll().first(where: { $0.id == thoughtID }) else { return }

            // 3. Swap in the combined file through the COORDINATED atomic-replace seam. On failure or a nil
            //    return (the slot vanished - a delete raced the swap; `replaceAudio` made no orphan), the
            //    fallback stands. `replaceAudio` consumes `combinedURL` on a nil return, but the defer's
            //    removeItem is a harmless no-op on an already-gone file.
            let replaced: URL?
            do {
                replaced = try store.replaceAudio(from: combinedURL, for: thoughtID)
            } catch {
                return
            }
            guard replaced != nil else { return }

            // 4. OFFSET the newly-recorded paragraphs (index >= existingParagraphCount) past the existing
            //    audio by the combined file's MEASURED existing-duration. The pre-existing paragraphs still
            //    point at the unchanged original audio at the front of the join, so they are left exactly as
            //    captured; the new paragraphs' `committedTimings` are relative to the new segment (joined as
            //    captured), so a single offset places them on the combined timeline. Applied to the FRESH
            //    thought (its title / paragraph EDITS are preserved) - but only when the fresh thought still
            //    has the SAME paragraph count, so the timings still align 1:1. A concurrent edit that
            //    ADDED/REMOVED a paragraph broke the alignment, so keep the fresh thought's own timings
            //    against the (now longer) recording - a seek slip, not data loss.
            let offset = RecordingTiming.offsetResumedTimings(
                committedTimings,
                existingParagraphCount: existingParagraphCount,
                existingDuration: existingDuration
            )
            let offsetThought = current.paragraphs.count == offset.count
                ? current.withTimings(offset)
                : current

            // 5. RE-CONFIRM the thought still exists immediately before the final save (security review).
            //    There is a SECOND delete-race window AFTER the swap: a soft-delete (spec 0020 trash) that
            //    lands between `replaceAudio` succeeding and this save moves `<id>.md`/`.m4a` into `.trash/`,
            //    and `save` - finding no live file (`locateFile` skips the trashed one) - would write a FRESH
            //    `<id>.md` at root, RESURRECTING the deleted thought's title + paragraphs as a live,
            //    audio-less thought. So skip the save entirely when the thought is gone. (Leaving the
            //    already-swapped audio on the trashed file is fine: a restore just gets the concatenated
            //    version.) The timings-save is only an optimization; the recording already continues.
            guard store.loadAll().contains(where: { $0.id == thoughtID }) else { return }
            _ = try? store.save(offsetThought)

            // Reload so the host drops the stale (un-offset, original-audio) in-memory thought. Reuses the
            // `onBackgroundAudioResave` hook: both are "a background audio re-save landed, refresh the feed."
            await MainActor.run { [weak self] in self?.onBackgroundAudioResave?() }
        }
    }

    /// Build and save the current thought, optionally adopting the session's recording into storage.
    ///
    /// When `adoptingRecording` is true and the capture service produced a recording, the temp file
    /// is moved into the thought's audio slot and the thought is saved WITH its audio filename and
    /// timings. If adopting the audio fails, the thought is still saved text-only (the words are never
    /// lost for the sake of the recording). Without a recording, the thought saves exactly as before.
    @discardableResult
    private func saveCurrentThought(adoptingRecording: Bool) throws -> Thought {
        // A resumed thought the user titled keeps that title (spec 0009); everything else derives from
        // the first sentence.
        let title = hasCustomTitle
            ? (customTitle ?? Thought.deriveTitle(paragraphs: paragraphs, createdAt: createdAt))
            : Thought.deriveTitle(paragraphs: paragraphs, createdAt: createdAt)

        // Save the thought FILE FIRST, before adopting any recording (spec 0010). The store places the
        // recording BESIDE the thought's `.md` (it locates the thought file to find the folder), so the
        // `.md` must exist in its folder before the `.m4a` is moved in - otherwise, with subfolders,
        // the recording would land at the root instead of beside its thought. A text-only thought is written
        // now; if a recording is then adopted, the thought is re-saved with its audio metadata. The file
        // is already in the thought's `folderPath`, so the re-save is an in-place overwrite, not a move.
        let textOnlyThought = Thought(
            id: thoughtID,
            title: title,
            paragraphs: paragraphs,
            createdAt: createdAt,
            hasCustomTitle: hasCustomTitle,
            audioFileName: nil,
            timings: [],
            folderPath: folderPath
        )
        try store.save(textOnlyThought)

        // Only the FINAL thought (Stop) adopts the recording: mid-session "new thought" saves text-only,
        // because the one continuous session file is not finalized until Stop. Never discard the
        // recording here - the writer may still be live for a following thought; `finish()` owns
        // discarding a recording that ends up attached to nothing.
        var audioFileName: String?
        var timings: [ParagraphTiming] = []
        if let existingAudioFileName {
            // Resumed thought that ALREADY had a recording. KEEP the original recording (never overwrite
            // the slot with just the new segment): its per-paragraph timings map to it, and the new
            // paragraphs get zero-length placeholders so they play back via text-to-speech. This is BOTH
            // the pre-0022 behavior and the SAFE FALLBACK: `finish()` then schedules an off-main
            // concatenation (feedback 0022) that, on success, joins the new segment onto this original and
            // re-saves with the new paragraphs' offset timings. On failure the thought stays exactly as
            // saved here, so the original recording is never lost.
            audioFileName = existingAudioFileName
            timings = resumeFallbackTimings()
        } else if adoptingRecording,
                  recordsAudio,
                  let recordingURL = service.recordingURL(),
                  let attached = try? attachRecording(recordingURL) {
            // A fresh session, or a resumed TEXT-ONLY thought gaining audio (spec 0013): the new recording
            // IS the thought's recording, so adopt it into the empty slot.
            audioFileName = attached.fileName
            timings = attached.timings
        }

        // No recording to attach: the text-only thought already on disk is the final thought.
        guard audioFileName != nil else { return textOnlyThought }

        // Re-save with the recording metadata now that the `.m4a` sits beside the `.md`.
        let thought = Thought(
            id: thoughtID,
            title: title,
            paragraphs: paragraphs,
            createdAt: createdAt,
            hasCustomTitle: hasCustomTitle,
            audioFileName: audioFileName,
            timings: timings,
            folderPath: folderPath
        )
        try store.save(thought)
        return thought
    }

    /// Move the session's recording into the thought's audio slot and build its per-paragraph timings.
    /// Returns nil (so the caller falls back to a text-only save) when the store keeps no audio.
    private func attachRecording(_ recordingURL: URL) throws -> (fileName: String, timings: [ParagraphTiming])? {
        guard let destination = store.audioURL(for: thoughtID) else { return nil }
        try store.saveAudio(from: recordingURL, for: thoughtID)
        // Trailing nils (partials, command-folded text) carry no timing; a thought with no real timing
        // at all is effectively text-only, so return nil and let the thought save without audio.
        let resolved = resolvedTimings()
        guard resolved.contains(where: { $0.duration > 0 }) else {
            try? store.deleteAudio(for: thoughtID)
            return nil
        }
        return (destination.lastPathComponent, resolved)
    }

    /// The per-paragraph timings for the thought, one per paragraph. A paragraph with no recorded range
    /// gets a zero-length placeholder so the array lines up 1:1 with `paragraphs` and an old index
    /// never maps to the wrong paragraph.
    private func resolvedTimings() -> [ParagraphTiming] {
        paragraphs.indices.map { index in
            paragraphTimings.indices.contains(index) ? paragraphTimings[index] : nil
        }.map { $0 ?? ParagraphTiming(start: 0, duration: 0) }
    }

    /// The per-paragraph timings for a resumed thought that KEEPS its original recording (feedback 0022
    /// fallback): the PRE-EXISTING paragraphs keep their real ranges into the original recording, but every
    /// paragraph added THIS session (index >= `existingParagraphCount`) is a zero-length placeholder.
    ///
    /// The new paragraphs' committed ranges are relative to the NEW segment, which is NOT part of the saved
    /// recording here - only the original is. So they must NOT point into the original (playback would seek
    /// to the wrong audio); they play back via text-to-speech until the off-main concatenation lands and
    /// re-saves them with their real OFFSET ranges. On a concatenation failure this is the final state.
    private func resumeFallbackTimings() -> [ParagraphTiming] {
        paragraphs.indices.map { index in
            guard index < existingParagraphCount,
                  paragraphTimings.indices.contains(index),
                  let timing = paragraphTimings[index] else {
                return ParagraphTiming(start: 0, duration: 0)
            }
            return timing
        }
    }

    /// Discard the session's recording temp file. Goes through the service (not `recordingURL()`) so
    /// even a zero-frame file - which `recordingURL()` would not report - is removed, leaving no
    /// orphan recording on disk. Safe to call when there is nothing to discard.
    private func discardPendingRecording() {
        service.discardRecording()
    }

    /// Replace the captured transcript with hand-edited text (feedback 0008 keyboard editing), used
    /// when the user edits the paused transcript on the record screen. The text is re-split into
    /// paragraphs and the live partial is cleared (its content is now part of the edited text).
    /// Hand-edited text no longer lines up with the recorded ranges, so any timing slots past the new
    /// paragraph count are dropped; remaining paragraphs whose text changed simply fall back to
    /// text-to-speech on playback (the thought model tolerates a timing that does not match its text).
    func applyEditedTranscript(_ text: String) {
        paragraphs = Thought.splitParagraphs(text)
        partial = ""
        if paragraphTimings.count > paragraphs.count {
            paragraphTimings = Array(paragraphTimings.prefix(paragraphs.count))
        }
        // A keyboard edit can drop paragraphs (feedback 0022): keep the resume boundary from drifting past
        // the end so a later dictated paragraph is still correctly offset onto the combined timeline.
        clampExistingParagraphCount()
    }

    /// The editable transcript text for the record screen: committed paragraphs plus the live
    /// partial, joined by blank lines so editing preserves paragraph breaks.
    var editableTranscript: String {
        displayParagraphs.joined(separator: "\n\n")
    }

    /// Discard the session without saving (used when the user backs out empty).
    func cancel() {
        service.stop()
        speaker.stop()
        // Drop the session's recording so a cancelled session leaves no orphan temp file.
        discardPendingRecording()
        level = 0
    }

    /// Inject text as if it had been finalized. Used by screenshot tooling and by tests to prove
    /// the save flow (and command routing) without live audio in the simulator. No timing, so the
    /// injected paragraph behaves as text-only on playback.
    func injectFinalized(_ text: String) {
        handleFinalized(text, range: nil)
    }

    /// Inject finalized text WITH a recording range, so tests can prove paragraph <-> time mapping
    /// and ranged playback without live audio.
    func injectFinalized(_ text: String, range: ParagraphTiming?) {
        handleFinalized(text, range: range)
    }

    /// Set the live partial as if speech recognition had reported it. Test hook mirroring
    /// `injectFinalized`, used to prove a partial present at `finish()` lands in the saved thought.
    /// A partial is only ever shown as text: a half-spoken command must not fire until it
    /// finalizes, so non-text results are ignored here.
    func simulatePartial(_ text: String) {
        partial = partialText(from: processor.process(text))
    }

    // MARK: - Event handling

    private func handle(_ event: SpeechCaptureEvent) {
        switch event {
        case .partial(let text):
            partial = partialText(from: processor.process(text))
        case .finalizedSegment(let text, let range, let startSeconds, let durationSeconds, let isAnalysisStart):
            handleFinalized(
                text,
                range: range,
                startSeconds: startSeconds,
                durationSeconds: durationSeconds,
                isAnalysisStart: isAnalysisStart
            )
        case .level(let value):
            // Simple smoothing so bars glide rather than jump.
            level = level * 0.6 + value * 0.4
        case .failure(let error):
            phase = .denied(DeniedReason(error))
            level = 0
        }
    }

    /// Route a finalized segment through the processor: commit text (with its recording range), or
    /// SPLIT it into a leading dictation paragraph plus a command (feedback 0006). On device a whole
    /// passage accumulates into one segment, so a spoken command lands mid/end of it, not at its
    /// start; the split commits the pre-keyword words and then runs (or drops) the command.
    ///
    /// Feedback 0012: dictation text no longer becomes one paragraph per finalized result. The pure
    /// `ParagraphGrouper` decides, from the silence gap between segments, whether the text FLOWS into
    /// the current paragraph or STARTS a new one, so a mid-thought breath stays in one paragraph and
    /// only a real pause breaks. `startSeconds` / `durationSeconds` default to a non-finite value and
    /// `isAnalysisStart` to true so the injection test hooks and any caller without timing keep the old
    /// "one segment = one paragraph" behavior.
    ///
    /// The grouper's anchor tracks COMMITTED paragraph time, not the raw result stream (PR #24 review):
    /// `grouper.decide` is called only AFTER `processor.process` and only for a segment that actually
    /// commits or appends dictation TEXT. An empty / whitespace-only segment and a pure-command segment
    /// (a split with empty pre-text) never advance the anchor and never create a paragraph, so a blank
    /// finalized result mid-flow cannot poison the gap the NEXT real segment is measured against.
    private func handleFinalized(
        _ text: String,
        range: ParagraphTiming?,
        startSeconds: Double = .nan,
        durationSeconds: Double = .nan,
        isAnalysisStart: Bool = true
    ) {
        let segment = processor.process(text)
        switch segment {
        case .text(let value):
            // Only a segment with real dictation text advances the grouper. A whitespace-only result
            // decides nothing and leaves the anchor where the last committed text left it.
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                partial = ""
                return
            }
            let decision = grouper.decide(
                startSeconds: startSeconds,
                durationSeconds: durationSeconds,
                isAnalysisStart: isAnalysisStart
            )
            switch decision {
            case .newParagraph:
                commitParagraph(value, range: range)
            case .appendToCurrent:
                appendToCurrentParagraph(value, range: range)
            }
            partial = ""
        case .split(let preText, let outcome):
            // The dictation before the control word is a real paragraph; commit it (guarded empty).
            // The segment's recording range spans the whole utterance including the command tail, so
            // it no longer maps cleanly to just the pre-text; drop the range (nil) rather than
            // over-claim it, so playback falls back to text-to-speech for this paragraph.
            //
            // A split is always its OWN paragraph boundary, so it commits directly rather than
            // consulting the grouper. Advance the grouper's anchor ONLY when the split actually commits
            // pre-text (a real paragraph): a pure-command split (empty pre-text) commits nothing, so it
            // must not advance the anchor or the next real segment's gap would be measured wrong.
            let hadPreText = !preText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hadPreText {
                _ = grouper.decide(
                    startSeconds: startSeconds,
                    durationSeconds: durationSeconds,
                    isAnalysisStart: isAnalysisStart
                )
            }
            commitParagraph(preText, range: nil)
            // When the split had pre-text, clear the live partial: on device the accumulating segment
            // finalizes while its own partial still echoes the SAME pre-keyword words ("P1" for
            // "P1 Mira new thought"), so that partial is now a stale duplicate of the paragraph just
            // committed. Leaving it would let a following command (`new thought` / `read that back`) fold
            // it in and append "P1" a SECOND time, or make read-back target the wrong paragraph.
            //
            // When there was NO pre-text (the segment LED with the control word), the live partial is
            // separate, genuine user content from a prior in-progress phrase - NOT an echo - so it is
            // left for `new thought` / `read that back` to fold in as before.
            if hadPreText { partial = "" }
            switch outcome {
            case .command(let command):
                execute(command)
            case .unrecognizedCommand:
                // Led with the control word but not a known command (feedback 0005): command mode,
                // so it is NOT transcribed. Show a brief chip so the user knows it was treated as a
                // command rather than silently lost. Leave the live partial (separate user content).
                showUnrecognizedCommandBanner()
            }
        case .drop:
            partial = ""
        }
    }

    /// The text a partial should display. A partial with no control word shows in full; once a
    /// control-word token is present the segment is splitting into command mode, so only the
    /// pre-keyword dictation is shown - the forming command must not be displayed (and must not
    /// fire, which it cannot: commands execute only on finalization, never on a live partial).
    private func partialText(from segment: ProcessedSegment) -> String {
        switch segment {
        case .text(let value):
            return value
        case .split(let preText, _):
            return preText
        case .drop:
            // A dropped segment has no displayable content; clear the live partial rather than
            // leaving the stale prior value on screen.
            return ""
        }
    }

    /// Reset the paragraph grouper at a THOUGHT boundary (feedback 0012, PR #24 review), so its running
    /// gap anchor does not carry over from the previous thought's last committed segment into the fresh
    /// thought. The first committed segment of the new thought is then always its own paragraph. Called from
    /// `startNewThought`; a fresh view model already starts with a clean grouper.
    private func resetForNewThought() {
        grouper = ParagraphGrouper()
    }

    private func commitParagraph(_ text: String, range: ParagraphTiming? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        paragraphs.append(trimmed)
        // Keep timings in lockstep with paragraphs: append the range (or a nil placeholder) so the
        // two arrays never drift, even for a paragraph committed without a recording range.
        paragraphTimings.append(range)
    }

    /// Flow a finalized segment into the CURRENT (last) paragraph rather than starting a new one
    /// (feedback 0012), joining with a single space so a mid-thought breath reads as one paragraph.
    ///
    /// The caller only reaches here on an `.appendToCurrent` decision, and the grouper returns that
    /// only AFTER a prior segment committed text (it forces `.newParagraph` for the first committed
    /// segment, and a fresh thought resets the grouper - see `resetForNewThought`). So `paragraphs` is
    /// guaranteed non-empty here; there is no empty-thought fallback (it was dead once the grouper's anchor
    /// tracks committed text). The caller pre-guards the text is non-empty.
    ///
    /// Timings merge through the pure `ParagraphTiming.merged`, so an append never silently degrades a
    /// real range to text-only: a paragraph that began text-only but gained a recorded tail ADOPTS that
    /// tail's range, both-present ranges span first-start-through-last-end, and the arrays never grow
    /// apart - an append never adds a timing slot.
    private func appendToCurrentParagraph(_ text: String, range: ParagraphTiming?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let lastIndex = paragraphs.indices.last else { return }
        paragraphs[lastIndex] = paragraphs[lastIndex] + " " + trimmed
        if paragraphTimings.indices.contains(lastIndex) {
            paragraphTimings[lastIndex] = ParagraphTiming.merged(paragraphTimings[lastIndex], range)
        }
    }

    // MARK: - Command execution

    /// Run a recognized Mira command against the in-progress thought. Surfaces the success chip only
    /// when the command had an actual effect (a no-op on an empty thought shows nothing), and surfaces
    /// an error indication instead of the chip when "new thought" fails to save.
    private func execute(_ command: MiraCommand) {
        switch command {
        case .removeLastSentence:
            if removeLastSentence() { showBanner(CommandBanner(command)) }
        case .removeLastParagraph:
            if removeLastParagraph() { showBanner(CommandBanner(command)) }
        case .newThought:
            switch startNewThought() {
            case .saved:
                showBanner(CommandBanner(command))
            case .emptyReset:
                // No content to save: a fresh empty thought is not a user-visible effect, so no chip.
                break
            case .saveFailed:
                commandError = .newThoughtSaveFailed
            }
        case .readThatBack:
            if readThatBack() { showBanner(CommandBanner(command)) }
        }
    }

    /// Drop the last sentence of the last paragraph; drop the paragraph if it empties. Returns
    /// true when it removed something (an actual effect), false on an empty thought.
    @discardableResult
    private func removeLastSentence() -> Bool {
        guard let last = paragraphs.last else { return false }
        if let remaining = SentenceTokenizer.removingLastSentence(from: last) {
            paragraphs[paragraphs.count - 1] = remaining
            // The paragraph shrank but is still present; its recorded range no longer matches the
            // edited text, so drop the timing (playback falls back to text-to-speech for it).
            if !paragraphTimings.isEmpty { paragraphTimings[paragraphTimings.count - 1] = nil }
        } else {
            paragraphs.removeLast()
            if !paragraphTimings.isEmpty { paragraphTimings.removeLast() }
        }
        clampExistingParagraphCount()
        return true
    }

    /// Drop the last committed paragraph. Returns true when it removed one, false on an empty thought.
    @discardableResult
    private func removeLastParagraph() -> Bool {
        guard !paragraphs.isEmpty else { return false }
        paragraphs.removeLast()
        if !paragraphTimings.isEmpty { paragraphTimings.removeLast() }
        clampExistingParagraphCount()
        return true
    }

    /// Keep the resume boundary `existingParagraphCount` from drifting past the end of `paragraphs`
    /// (feedback 0022, architect review). Mira's `remove last paragraph/sentence` (and a keyboard edit)
    /// delete from the END, so a removal can eat into the PRE-EXISTING region; without this, a
    /// subsequently dictated new paragraph would land at an index BELOW the stale boundary and be treated
    /// as pre-existing - never offset onto the combined timeline, leaving its range pointing at the front
    /// of the recording (a seek slip). Clamping the boundary to the current paragraph count keeps the
    /// new-vs-existing split honest: a removed pre-existing paragraph shrinks the pre-existing region.
    private func clampExistingParagraphCount() {
        existingParagraphCount = min(existingParagraphCount, paragraphs.count)
    }

    /// The outcome of a "new thought" command, so `execute` can pick the right feedback.
    private enum NewThoughtOutcome {
        case saved       // saved the current thought and reset to a fresh one
        case emptyReset  // nothing to save, reset a fresh empty thought (no user-visible effect)
        case saveFailed  // store threw: content is PRESERVED, surface an error
    }

    /// Save the current thought (if any) and reset to a fresh one, keeping the session running.
    ///
    /// On a save FAILURE the current content is PRESERVED (paragraphs/partial/thoughtID untouched) so
    /// it is not lost or bled into the next thought, and the caller surfaces an error instead of the
    /// success chip. On SUCCESS the thought resets and the caller shows the success chip.
    private func startNewThought() -> NewThoughtOutcome {
        foldPartialIntoParagraphs()
        let hadContent = !paragraphs.isEmpty
        if hadContent {
            do {
                // Mid-session "new thought" saves the transcript only: the session's recording is one
                // continuous file, finalized at Stop and attached to the FINAL thought, so an
                // intermediate thought cannot claim a finished recording. The words are always kept.
                try saveCurrentThought(adoptingRecording: false)
            } catch {
                // Preserve content: do NOT reset. Surfacing the failure lets the user retry (or
                // Stop) without silently double-saving or bleeding this thought into the next.
                return .saveFailed
            }
        }
        paragraphs = []
        paragraphTimings = []
        partial = ""
        resetForNewThought()
        thoughtID = UUID()
        createdAt = Date()
        // A fresh thought is created at the top level; it is filed into a folder afterward (spec 0010).
        folderPath = []
        // Clear the resumed thought's recording reference too: the just-saved thought kept it, but the fresh
        // thought is a NEW recording (or none). Leaving it set would attach the original recording to the
        // new thought on Stop, so two thoughts would point at the same file (engineer review, feedback 0008).
        // Clear the resume-concatenation anchor too (feedback 0022): the fresh thought has no existing
        // recording to join onto, so any new audio it records is adopted fresh, not concatenated.
        existingAudioFileName = nil
        existingParagraphCount = 0
        return hadContent ? .saved : .emptyReset
    }

    /// Speak the last paragraph aloud, pausing capture so the audio does not feed back in.
    /// Returns true if there was something to read (an actual effect), false on a no-op empty thought.
    @discardableResult
    private func readThatBack() -> Bool {
        foldPartialIntoParagraphs()
        guard let last = paragraphs.last else { return false }
        // Capture `wasRecording` up front. This is the source of truth for whether to resume: the
        // phase is set to `.readingBack` below and the user may tap Pause mid-playback, so
        // `readBackDidFinish` must NOT key off `phase == .recording` (that caused the stuck state).
        let wasRecording = (phase == .recording)
        if wasRecording {
            // Pause capture (tears down engine/task, deactivates the record session) so the mic is
            // not hearing the synthesizer. `readBackDidFinish` restores it.
            service.pause()
            level = 0
        }
        wasRecordingBeforeReadBack = wasRecording
        isReadingBack = true
        // Reflect the true state in the UI while playback runs, so the screen is honest.
        if wasRecording { phase = .readingBack }
        // In-session read-back speaks via text-to-speech. The session's recording is a LIVE `.m4a`
        // still open for writing - the writer is finalized only at `stop()`, never on the `pause()`
        // this path uses - so it has no finalized container `AVAudioPlayer` could open. Recorded
        // playback of the ACTUAL voice happens for a SAVED thought through the shared
        // `ThoughtPlaybackController` (the bottom player), where the file is finalized.
        // `speaker.onFinish` and `audioPlayer.onFinish` share
        // `readBackDidFinish`, so the resume handshake is identical whichever plays.
        speaker.speak(last)
        return true
    }

    /// Restore capture once read-back finishes. Guarded by `isReadingBack` (not `phase`), so a
    /// Pause tapped mid-playback cannot leave capture permanently torn down.
    private func readBackDidFinish() {
        guard isReadingBack else { return }
        isReadingBack = false
        // Only resume if capture was recording when read-back began AND the user did not pause
        // during playback (`togglePause` clears `wasRecordingBeforeReadBack` in that case).
        if wasRecordingBeforeReadBack {
            phase = .recording
            service.resume()
        } else if phase == .readingBack {
            // Read-back began while not recording; land back in a paused, non-stuck state.
            phase = .paused
        }
        wasRecordingBeforeReadBack = false
    }

    /// Fold any live partial into the committed paragraphs (used before save/read-back). The partial
    /// was never finalized, so it has no recording range: append a nil placeholder to keep timings in
    /// lockstep, and it plays back via text-to-speech.
    private func foldPartialIntoParagraphs() {
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            paragraphs.append(trimmed)
            paragraphTimings.append(nil)
            partial = ""
        }
    }

    /// Show the command chip and auto-dismiss it after a moment. The full label (control word plus
    /// the effect, e.g. "Mira - new thought") is assembled here so the view renders a plain string.
    private func showBanner(_ banner: CommandBanner) {
        showBannerLabel("\(controlWord) - \(banner.label)")
    }

    /// The chip shown when a keyword-led phrase was treated as a command but matched none (feedback
    /// 0005), so the user knows their words were dropped as a command rather than silently lost.
    private func showUnrecognizedCommandBanner() {
        showBannerLabel("Sorry, I didn't catch that command")
    }

    /// Set the transient chip label and schedule its auto-dismiss.
    private func showBannerLabel(_ label: String) {
        commandError = nil
        commandBanner = label
        bannerTask?.cancel()
        bannerTask = Task { [weak self, bannerDuration] in
            try? await Task.sleep(for: bannerDuration)
            guard !Task.isCancelled else { return }
            self?.commandBanner = nil
        }
    }
}
