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

        /// The chip label, e.g. "removed last sentence". The control word prefix is added by the
        /// view so the whole chip reads "Mira - removed last sentence".
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
    /// The most recent command chip, or nil. Set when a command fires, cleared after a moment.
    @Published private(set) var commandBanner: CommandBanner?

    private let service: SpeechCaptureService
    private let store: NoteStoring
    private let processor: TextProcessor
    private let speaker: Speaker
    private var createdAt = Date()
    private var noteID = UUID()

    /// How long the command chip stays up before auto-dismissing.
    private let bannerDuration: Duration = .seconds(2)
    private var bannerTask: Task<Void, Never>?

    /// True while Mira reads a paragraph aloud and capture is paused for it, so `didFinish`
    /// resumes capture only when read-back was the thing that paused it.
    private var isReadingBack = false

    init(
        service: SpeechCaptureService? = nil,
        store: NoteStoring,
        processor: TextProcessor = PassthroughTextProcessor(),
        speaker: Speaker? = nil
    ) {
        // Build the production service here (on the main actor) when none is injected, so the
        // service's main-actor-isolated initializer is not called from a nonisolated default.
        self.service = service ?? SpeechDictationService()
        self.store = store
        self.processor = processor
        self.speaker = speaker ?? SystemSpeaker()
        self.service.onEvent = { [weak self] event in
            self?.handle(event)
        }
        self.speaker.onFinish = { [weak self] in
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
            phase = .saved
            return nil
        }

        let title = Note.deriveTitle(paragraphs: paragraphs, createdAt: createdAt)
        let note = Note(id: noteID, title: title, paragraphs: paragraphs, createdAt: createdAt)
        try store.save(note)
        phase = .saved
        return note
    }

    /// Discard the session without saving (used when the user backs out empty).
    func cancel() {
        service.stop()
        level = 0
    }

    /// Inject text as if it had been finalized. Used by screenshot tooling and by tests to prove
    /// the save flow (and command routing) without live audio in the simulator.
    func injectFinalized(_ text: String) {
        handleFinalized(text)
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
        case .finalizedSegment(let text):
            handleFinalized(text)
        case .level(let value):
            // Simple smoothing so bars glide rather than jump.
            level = level * 0.6 + value * 0.4
        case .failure(let error):
            phase = .denied(DeniedReason(error))
            level = 0
        }
    }

    /// Route a finalized segment through the processor: commit text, or run a command.
    private func handleFinalized(_ text: String) {
        switch processor.process(text) {
        case .text(let value):
            commitParagraph(value)
            partial = ""
        case .command(let command):
            // A command is consumed: it never lands in the note. Clear the partial so the
            // spoken phrase does not linger under the caret.
            partial = ""
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

    private func commitParagraph(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        paragraphs.append(trimmed)
    }

    // MARK: - Command execution

    /// Run a recognized Mira command against the in-progress note and surface a chip.
    private func execute(_ command: MiraCommand) {
        switch command {
        case .removeLastSentence:
            removeLastSentence()
        case .removeLastParagraph:
            removeLastParagraph()
        case .newNote:
            startNewNote()
        case .readThatBack:
            readThatBack()
        }
        showBanner(CommandBanner(command))
    }

    /// Drop the last sentence of the last paragraph; drop the paragraph if it empties.
    private func removeLastSentence() {
        guard let last = paragraphs.last else { return }
        if let remaining = SentenceTokenizer.removingLastSentence(from: last) {
            paragraphs[paragraphs.count - 1] = remaining
        } else {
            paragraphs.removeLast()
        }
    }

    /// Drop the last committed paragraph.
    private func removeLastParagraph() {
        guard !paragraphs.isEmpty else { return }
        paragraphs.removeLast()
    }

    /// Save the current note (if any) and reset to a fresh one, keeping the session running.
    private func startNewNote() {
        foldPartialIntoParagraphs()
        if !paragraphs.isEmpty {
            let title = Note.deriveTitle(paragraphs: paragraphs, createdAt: createdAt)
            let note = Note(id: noteID, title: title, paragraphs: paragraphs, createdAt: createdAt)
            // A save failure here is non-fatal: keep the session going rather than interrupt
            // hands-free capture. The note stays on screen if it could not be written.
            do {
                try store.save(note)
            } catch {
                return
            }
        }
        paragraphs = []
        partial = ""
        noteID = UUID()
        createdAt = Date()
    }

    /// Speak the last paragraph aloud, pausing capture so the audio does not feed back in.
    private func readThatBack() {
        foldPartialIntoParagraphs()
        guard let last = paragraphs.last else { return }
        // Pause capture (tears down engine/task, deactivates the record session) so the mic is
        // not hearing the synthesizer. `readBackDidFinish` resumes it.
        if phase == .recording {
            service.pause()
            level = 0
        }
        isReadingBack = true
        speaker.speak(last)
    }

    /// Restore capture once read-back finishes, if it was recording when read-back began.
    private func readBackDidFinish() {
        guard isReadingBack else { return }
        isReadingBack = false
        if phase == .recording {
            service.resume()
        }
    }

    /// Fold any live partial into the committed paragraphs (used before save/read-back).
    private func foldPartialIntoParagraphs() {
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            paragraphs.append(trimmed)
            partial = ""
        }
    }

    /// Show the command chip and auto-dismiss it after a moment.
    private func showBanner(_ banner: CommandBanner) {
        commandBanner = banner
        bannerTask?.cancel()
        bannerTask = Task { [weak self, bannerDuration] in
            try? await Task.sleep(for: bannerDuration)
            guard !Task.isCancelled else { return }
            self?.commandBanner = nil
        }
    }
}
