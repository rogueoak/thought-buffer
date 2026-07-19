import Foundation
import SwiftUI

/// Drives the dictation screen: holds the growing note, the live partial phrase, the mic level,
/// and the capture phase, and coordinates the speech service and the note store.
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
                return "Thought Stream needs speech recognition to turn your voice into notes. "
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
        case newNote
        case readThatBack

        init(_ command: MiraCommand) {
            switch command {
            case .removeLastSentence: self = .removedLastSentence
            case .removeLastParagraph: self = .removedLastParagraph
            case .newNote: self = .newNote
            case .readThatBack: self = .readThatBack
            }
        }

        /// The effect portion of the chip label, e.g. "removed last sentence". `showBanner`
        /// prepends the control word so the whole chip reads "Mira - removed last sentence".
        var label: String {
            switch self {
            case .removedLastSentence: return "removed last sentence"
            case .removedLastParagraph: return "removed last paragraph"
            case .newNote: return "new note"
            case .readThatBack: return "read that back"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    /// Finalized paragraphs committed to the note so far.
    @Published private(set) var paragraphs: [String] = []
    /// The in-progress phrase for the current task, shown live with a caret.
    @Published private(set) var partial: String = ""
    /// Smoothed microphone level, 0...1, for the waveform.
    @Published private(set) var level: Float = 0
    /// The most recent command chip label, or nil. Set when a command has an actual effect,
    /// cleared after a moment. Assembled here (where the active control word is known) so the view
    /// renders a plain string and stays correct when Settings makes the control word configurable.
    @Published private(set) var commandBanner: String?
    /// Set when a voice command (currently "Mira new note") fails to save, so the view surfaces an
    /// error rather than the success chip. The current content is preserved on screen.
    @Published private(set) var commandError: CommandError?

    /// A voice command that could not complete, surfaced to the view instead of a success chip.
    enum CommandError: Equatable {
        /// "Mira new note" could not save the current note; its content is preserved on screen.
        case newNoteSaveFailed
    }

    private let service: SpeechCaptureService
    private let store: NoteStoring
    private let processor: TextProcessor
    private let speaker: Speaker
    /// Whether to record the session's audio (spec 0007). Read from settings at construction so it
    /// applies to this session; `transcriptOnly` never opens the file writer.
    private let recordsAudio: Bool
    /// The active control word, used to assemble the command chip label (e.g. "Mira - new note") and
    /// shown on the cheat sheet (feedback 0008). Injected so it stays in sync with the processor's
    /// control word once Settings makes it configurable, keeping the chip prefix out of the view.
    let controlWord: String
    private var createdAt = Date()
    private var noteID = UUID()
    /// The folder the note is saved into (spec 0010). A fresh session is created at the TOP LEVEL
    /// (empty) - notes are filed into folders afterward via PR B's move action. A RESUMED note keeps
    /// the folder it already lives in, so continuing it re-saves it in place rather than yanking it
    /// back to the root. Reset to top level when "new note" starts a fresh note mid-session.
    private var folderPath: [String] = []

    /// A user-set title carried over when RESUMING a note (spec 0009). A fresh session always
    /// auto-derives its title, but resuming a note the user titled must keep that title rather than
    /// re-deriving it from the (now longer) body. Nil / false for a fresh session.
    private var hasCustomTitle = false
    private var customTitle: String?

    /// The recording filename carried over when RESUMING an existing note (feedback 0008): a resumed
    /// session does not record new audio, so the note keeps its original recording. Nil for a fresh
    /// session, where any recording comes from the live capture instead.
    private var existingAudioFileName: String?

    /// One timing per committed paragraph, in lockstep with `paragraphs` (spec 0007). A finalized
    /// segment appends its range here as its text is committed; a paragraph committed without a range
    /// (a command-folded partial, or recording off) appends a nil placeholder so the arrays stay
    /// aligned. Trailing nils are trimmed when the note is built.
    private var paragraphTimings: [ParagraphTiming?] = []

    /// Decides whether a finalized segment flows into the current paragraph or starts a new one, by the
    /// silence gap between segments (feedback 0012). All the policy lives in the pure grouper; the view
    /// model only routes on its decision. Its anchor spans one NOTE's dictation and is RESET at a note
    /// boundary (`resetForNewNote`, called from `startNewNote`) so the gap never carries over from the
    /// previous note's last segment into the fresh note's first; a pause/resume seam within a note is
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
        store: NoteStoring,
        processor: TextProcessor = PassthroughTextProcessor(),
        speaker: Speaker? = nil,
        recordsAudio: Bool = false,
        controlWord: String = MiraTextProcessor.defaultControlWord,
        resuming: Note? = nil
    ) {
        // Build the production service here (on the main actor) when none is injected, so the
        // service's main-actor-isolated initializer is not called from a nonisolated default.
        self.service = service ?? SpeechAnalyzerService()
        self.store = store
        self.processor = processor
        self.speaker = speaker ?? SystemSpeaker()
        self.recordsAudio = recordsAudio
        self.controlWord = controlWord
        // Resuming an existing note (feedback 0008): keep its id, creation time, and text so the
        // session continues that note (saving overwrites the same file) rather than starting a new
        // one. New spoken content is appended as text; the original recording and its per-paragraph
        // timings are preserved for the existing paragraphs (a resumed session records no new audio,
        // so the caller passes recordsAudio: false), and anything appended is text-only on playback.
        if let resuming {
            noteID = resuming.id
            createdAt = resuming.createdAt
            paragraphs = resuming.paragraphs
            paragraphTimings = Self.seedTimings(for: resuming)
            existingAudioFileName = resuming.audioFileName
            // Keep the resumed note in the folder it already lives in, so continuing it re-saves in
            // place rather than relocating it to the top level.
            folderPath = resuming.folderPath
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

    /// The per-paragraph timing slots to seed when resuming a note, aligned 1:1 with its paragraphs:
    /// each paragraph keeps its recorded range (or nil when the note had no timing for it), so the
    /// preserved recording still maps to the original paragraphs after resume.
    private static func seedTimings(for note: Note) -> [ParagraphTiming?] {
        note.paragraphs.indices.map { note.timing(forParagraphAt: $0) }
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

    /// Stop capture and save the note. Returns the saved note, or nil if nothing was captured.
    /// Throws if the store fails to persist the note, so the caller can surface the failure
    /// instead of silently reporting success.
    @discardableResult
    func finish() throws -> Note? {
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

        // The session's recording (finalized by `service.stop()` above) belongs to this final note.
        let note = try saveCurrentNote(adoptingRecording: true)
        // A successful adopt MOVES the temp file into storage; if adopting was skipped or failed, a
        // temp file may linger. Clean it up so no orphan recording is left on disk.
        discardPendingRecording()
        phase = .saved
        return note
    }

    /// Build and save the current note, optionally adopting the session's recording into storage.
    ///
    /// When `adoptingRecording` is true and the capture service produced a recording, the temp file
    /// is moved into the note's audio slot and the note is saved WITH its audio filename and
    /// timings. If adopting the audio fails, the note is still saved text-only (the words are never
    /// lost for the sake of the recording). Without a recording, the note saves exactly as before.
    @discardableResult
    private func saveCurrentNote(adoptingRecording: Bool) throws -> Note {
        // A resumed note the user titled keeps that title (spec 0009); everything else derives from
        // the first sentence.
        let title = hasCustomTitle
            ? (customTitle ?? Note.deriveTitle(paragraphs: paragraphs, createdAt: createdAt))
            : Note.deriveTitle(paragraphs: paragraphs, createdAt: createdAt)

        // Save the note FILE FIRST, before adopting any recording (spec 0010). The store places the
        // recording BESIDE the note's `.md` (it locates the note file to find the folder), so the
        // `.md` must exist in its folder before the `.m4a` is moved in - otherwise, with subfolders,
        // the recording would land at the root instead of beside its note. A text-only note is written
        // now; if a recording is then adopted, the note is re-saved with its audio metadata. The file
        // is already in the note's `folderPath`, so the re-save is an in-place overwrite, not a move.
        let textOnlyNote = Note(
            id: noteID,
            title: title,
            paragraphs: paragraphs,
            createdAt: createdAt,
            hasCustomTitle: hasCustomTitle,
            audioFileName: nil,
            timings: [],
            folderPath: folderPath
        )
        try store.save(textOnlyNote)

        // Only the FINAL note (Stop) adopts the recording: mid-session "new note" saves text-only,
        // because the one continuous session file is not finalized until Stop. Never discard the
        // recording here - the writer may still be live for a following note; `finish()` owns
        // discarding a recording that ends up attached to nothing.
        var audioFileName: String?
        var timings: [ParagraphTiming] = []
        if adoptingRecording,
           recordsAudio,
           let recordingURL = service.recordingURL(),
           let attached = try? attachRecording(recordingURL) {
            audioFileName = attached.fileName
            timings = attached.timings
        } else if let existingAudioFileName {
            // Resumed note (feedback 0008): keep the original recording and its per-paragraph timings.
            // Appended paragraphs have no recorded range, so `resolvedTimings` pads them and they play
            // back via text-to-speech; the original paragraphs still map to the preserved audio.
            audioFileName = existingAudioFileName
            timings = resolvedTimings()
        }

        // No recording to attach: the text-only note already on disk is the final note.
        guard audioFileName != nil else { return textOnlyNote }

        // Re-save with the recording metadata now that the `.m4a` sits beside the `.md`.
        let note = Note(
            id: noteID,
            title: title,
            paragraphs: paragraphs,
            createdAt: createdAt,
            hasCustomTitle: hasCustomTitle,
            audioFileName: audioFileName,
            timings: timings,
            folderPath: folderPath
        )
        try store.save(note)
        return note
    }

    /// Move the session's recording into the note's audio slot and build its per-paragraph timings.
    /// Returns nil (so the caller falls back to a text-only save) when the store keeps no audio.
    private func attachRecording(_ recordingURL: URL) throws -> (fileName: String, timings: [ParagraphTiming])? {
        guard let destination = store.audioURL(for: noteID) else { return nil }
        try store.saveAudio(from: recordingURL, for: noteID)
        // Trailing nils (partials, command-folded text) carry no timing; a note with no real timing
        // at all is effectively text-only, so return nil and let the note save without audio.
        let resolved = resolvedTimings()
        guard resolved.contains(where: { $0.duration > 0 }) else {
            try? store.deleteAudio(for: noteID)
            return nil
        }
        return (destination.lastPathComponent, resolved)
    }

    /// The per-paragraph timings for the note, one per paragraph. A paragraph with no recorded range
    /// gets a zero-length placeholder so the array lines up 1:1 with `paragraphs` and an old index
    /// never maps to the wrong paragraph.
    private func resolvedTimings() -> [ParagraphTiming] {
        paragraphs.indices.map { index in
            paragraphTimings.indices.contains(index) ? paragraphTimings[index] : nil
        }.map { $0 ?? ParagraphTiming(start: 0, duration: 0) }
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
    /// text-to-speech on playback (the note model tolerates a timing that does not match its text).
    func applyEditedTranscript(_ text: String) {
        paragraphs = Note.splitParagraphs(text)
        partial = ""
        if paragraphTimings.count > paragraphs.count {
            paragraphTimings = Array(paragraphTimings.prefix(paragraphs.count))
        }
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
    /// `injectFinalized`, used to prove a partial present at `finish()` lands in the saved note.
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
            // "P1 Mira new note"), so that partial is now a stale duplicate of the paragraph just
            // committed. Leaving it would let a following command (`new note` / `read that back`) fold
            // it in and append "P1" a SECOND time, or make read-back target the wrong paragraph.
            //
            // When there was NO pre-text (the segment LED with the control word), the live partial is
            // separate, genuine user content from a prior in-progress phrase - NOT an echo - so it is
            // left for `new note` / `read that back` to fold in as before.
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

    /// Reset the paragraph grouper at a NOTE boundary (feedback 0012, PR #24 review), so its running
    /// gap anchor does not carry over from the previous note's last committed segment into the fresh
    /// note. The first committed segment of the new note is then always its own paragraph. Called from
    /// `startNewNote`; a fresh view model already starts with a clean grouper.
    private func resetForNewNote() {
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
    /// segment, and a fresh note resets the grouper - see `resetForNewNote`). So `paragraphs` is
    /// guaranteed non-empty here; there is no empty-note fallback (it was dead once the grouper's anchor
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

    /// Run a recognized Mira command against the in-progress note. Surfaces the success chip only
    /// when the command had an actual effect (a no-op on an empty note shows nothing), and surfaces
    /// an error indication instead of the chip when "new note" fails to save.
    private func execute(_ command: MiraCommand) {
        switch command {
        case .removeLastSentence:
            if removeLastSentence() { showBanner(CommandBanner(command)) }
        case .removeLastParagraph:
            if removeLastParagraph() { showBanner(CommandBanner(command)) }
        case .newNote:
            switch startNewNote() {
            case .saved:
                showBanner(CommandBanner(command))
            case .emptyReset:
                // No content to save: a fresh empty note is not a user-visible effect, so no chip.
                break
            case .saveFailed:
                commandError = .newNoteSaveFailed
            }
        case .readThatBack:
            if readThatBack() { showBanner(CommandBanner(command)) }
        }
    }

    /// Drop the last sentence of the last paragraph; drop the paragraph if it empties. Returns
    /// true when it removed something (an actual effect), false on an empty note.
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
        return true
    }

    /// Drop the last committed paragraph. Returns true when it removed one, false on an empty note.
    @discardableResult
    private func removeLastParagraph() -> Bool {
        guard !paragraphs.isEmpty else { return false }
        paragraphs.removeLast()
        if !paragraphTimings.isEmpty { paragraphTimings.removeLast() }
        return true
    }

    /// The outcome of a "new note" command, so `execute` can pick the right feedback.
    private enum NewNoteOutcome {
        case saved       // saved the current note and reset to a fresh one
        case emptyReset  // nothing to save, reset a fresh empty note (no user-visible effect)
        case saveFailed  // store threw: content is PRESERVED, surface an error
    }

    /// Save the current note (if any) and reset to a fresh one, keeping the session running.
    ///
    /// On a save FAILURE the current content is PRESERVED (paragraphs/partial/noteID untouched) so
    /// it is not lost or bled into the next note, and the caller surfaces an error instead of the
    /// success chip. On SUCCESS the note resets and the caller shows the success chip.
    private func startNewNote() -> NewNoteOutcome {
        foldPartialIntoParagraphs()
        let hadContent = !paragraphs.isEmpty
        if hadContent {
            do {
                // Mid-session "new note" saves the transcript only: the session's recording is one
                // continuous file, finalized at Stop and attached to the FINAL note, so an
                // intermediate note cannot claim a finished recording. The words are always kept.
                try saveCurrentNote(adoptingRecording: false)
            } catch {
                // Preserve content: do NOT reset. Surfacing the failure lets the user retry (or
                // Stop) without silently double-saving or bleeding this note into the next.
                return .saveFailed
            }
        }
        paragraphs = []
        paragraphTimings = []
        partial = ""
        resetForNewNote()
        noteID = UUID()
        createdAt = Date()
        // A fresh note is created at the top level; it is filed into a folder afterward (spec 0010).
        folderPath = []
        // Clear the resumed note's recording reference too: the just-saved note kept it, but the fresh
        // note is a NEW recording (or none). Leaving it set would attach the original recording to the
        // new note on Stop, so two notes would point at the same file (engineer review, feedback 0008).
        existingAudioFileName = nil
        return hadContent ? .saved : .emptyReset
    }

    /// Speak the last paragraph aloud, pausing capture so the audio does not feed back in.
    /// Returns true if there was something to read (an actual effect), false on a no-op empty note.
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
        // playback of the ACTUAL voice happens from a SAVED note's detail view (`NotePlaybackModel`),
        // where the file is finalized. `speaker.onFinish` and `audioPlayer.onFinish` share
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
    /// the effect, e.g. "Mira - new note") is assembled here so the view renders a plain string.
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
