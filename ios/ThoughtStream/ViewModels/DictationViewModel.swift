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
    /// Plays a paragraph's actual recording for "read that back" (spec 0007), falling back to the
    /// text-to-speech `speaker` when the note or paragraph has no audio. Injected so tests can assert
    /// what range played and stub the fallback.
    private let audioPlayer: AudioNotePlayer
    /// Whether to record the session's audio (spec 0007). Read from settings at construction so it
    /// applies to this session; `transcriptOnly` never opens the file writer.
    private let recordsAudio: Bool
    /// The active control word, used to assemble the command chip label (e.g. "Mira - new note").
    /// Injected so it stays in sync with the processor's control word once Settings makes it
    /// configurable, keeping the chip prefix out of the view.
    private let controlWord: String
    private var createdAt = Date()
    private var noteID = UUID()

    /// One timing per committed paragraph, in lockstep with `paragraphs` (spec 0007). A finalized
    /// segment appends its range here as its text is committed; a paragraph committed without a range
    /// (a command-folded partial, or recording off) appends a nil placeholder so the arrays stay
    /// aligned. Trailing nils are trimmed when the note is built.
    private var paragraphTimings: [ParagraphTiming?] = []

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
        audioPlayer: AudioNotePlayer? = nil,
        recordsAudio: Bool = false,
        controlWord: String = MiraTextProcessor.defaultControlWord
    ) {
        // Build the production service here (on the main actor) when none is injected, so the
        // service's main-actor-isolated initializer is not called from a nonisolated default.
        self.service = service ?? SpeechDictationService()
        self.store = store
        self.processor = processor
        self.speaker = speaker ?? SystemSpeaker()
        self.audioPlayer = audioPlayer ?? SystemAudioNotePlayer()
        self.recordsAudio = recordsAudio
        self.controlWord = controlWord
        // Tell the capture service whether to tee audio to a file for this session, before it starts.
        self.service.setRecordingEnabled(recordsAudio)
        self.service.onEvent = { [weak self] event in
            self?.handle(event)
        }
        self.speaker.onFinish = { [weak self] in
            self?.readBackDidFinish()
        }
        self.audioPlayer.onFinish = { [weak self] in
            self?.readBackDidFinish()
        }
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
        audioPlayer.stop()
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
        let title = Note.deriveTitle(paragraphs: paragraphs, createdAt: createdAt)

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
        }

        let note = Note(
            id: noteID,
            title: title,
            paragraphs: paragraphs,
            createdAt: createdAt,
            audioFileName: audioFileName,
            timings: timings
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

    /// Discard the session's recording temp file if the capture service left one. Safe to call when
    /// there is nothing to discard.
    private func discardPendingRecording() {
        if let recordingURL = service.recordingURL() {
            try? FileManager.default.removeItem(at: recordingURL)
        }
    }

    /// Discard the session without saving (used when the user backs out empty).
    func cancel() {
        service.stop()
        speaker.stop()
        audioPlayer.stop()
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
        case .finalizedSegment(let text, let range):
            handleFinalized(text, range: range)
        case .level(let value):
            // Simple smoothing so bars glide rather than jump.
            level = level * 0.6 + value * 0.4
        case .failure(let error):
            phase = .denied(DeniedReason(error))
            level = 0
        }
    }

    /// Route a finalized segment through the processor: commit text (with its recording range), or
    /// run a command. A command carries no paragraph, so its range is dropped.
    private func handleFinalized(_ text: String, range: ParagraphTiming?) {
        switch processor.process(text) {
        case .text(let value):
            commitParagraph(value, range: range)
            partial = ""
        case .command(let command):
            // A command is consumed: the command phrase itself never lands in the note (it arrived
            // as its own finalized segment). Do NOT blanket-clear the live partial here: it is a
            // separate in-progress phrase of real user content. Commands that need it (new note,
            // read that back) fold it in via `foldPartialIntoParagraphs`; the rest leave it intact.
            execute(command)
        case .drop:
            partial = ""
        }
    }

    /// The text a partial should display: only `.text` shows; a command mid-partial waits.
    private func partialText(from segment: ProcessedSegment) -> String {
        if case .text(let value) = segment { return value }
        return partial
    }

    private func commitParagraph(_ text: String, range: ParagraphTiming? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        paragraphs.append(trimmed)
        // Keep timings in lockstep with paragraphs: append the range (or a nil placeholder) so the
        // two arrays never drift, even for a paragraph committed without a recording range.
        paragraphTimings.append(range)
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
        noteID = UUID()
        createdAt = Date()
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
        // Prefer the ACTUAL recording of the last paragraph (spec 0007): play its recorded range if
        // there is one and a playable file. Otherwise fall back to text-to-speech. Both report
        // completion through `readBackDidFinish` (the player and speaker share the same callback), so
        // the resume handshake is identical.
        if let timing = lastParagraphTiming(),
           let recordingURL = service.recordingURL(),
           audioPlayer.play(url: recordingURL, from: timing.start, duration: timing.duration) {
            return true
        }
        speaker.speak(last)
        return true
    }

    /// The recorded range of the last committed paragraph, or nil when it has no real recording
    /// (recording off, a folded partial, or an edited paragraph whose timing was dropped).
    private func lastParagraphTiming() -> ParagraphTiming? {
        guard let timing = paragraphTimings.last ?? nil else { return nil }
        return timing.duration > 0 ? timing : nil
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
        commandError = nil
        commandBanner = "\(controlWord) - \(banner.label)"
        bannerTask?.cancel()
        bannerTask = Task { [weak self, bannerDuration] in
            try? await Task.sleep(for: bannerDuration)
            guard !Task.isCancelled else { return }
            self?.commandBanner = nil
        }
    }
}
