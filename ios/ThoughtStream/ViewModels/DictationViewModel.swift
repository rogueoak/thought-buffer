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

    @Published private(set) var phase: Phase = .idle
    /// Finalized paragraphs committed to the note so far.
    @Published private(set) var paragraphs: [String] = []
    /// The in-progress phrase for the current task, shown live with a caret.
    @Published private(set) var partial: String = ""
    /// Smoothed microphone level, 0...1, for the waveform.
    @Published private(set) var level: Float = 0

    private let service: SpeechCaptureService
    private let store: NoteStoring
    private let processor: TextProcessor
    private let createdAt = Date()
    private let noteID = UUID()

    init(
        service: SpeechCaptureService? = nil,
        store: NoteStoring,
        processor: TextProcessor = PassthroughTextProcessor()
    ) {
        // Build the production service here (on the main actor) when none is injected, so the
        // service's main-actor-isolated initializer is not called from a nonisolated default.
        self.service = service ?? SpeechDictationService()
        self.store = store
        self.processor = processor
        self.service.onEvent = { [weak self] event in
            self?.handle(event)
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
        // Fold any live partial into the committed paragraphs before saving. The partial is
        // already processed (see `handle`/`simulatePartial`), so append it directly rather than
        // running it through the processor a second time.
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            paragraphs.append(trimmed)
            partial = ""
        }
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
    /// the save flow without live audio in the simulator.
    func injectFinalized(_ text: String) {
        commitParagraph(text)
    }

    /// Set the live partial as if speech recognition had reported it. Test hook mirroring
    /// `injectFinalized`, used to prove a partial present at `finish()` lands in the saved note.
    func simulatePartial(_ text: String) {
        partial = processor.process(text)
    }

    // MARK: - Event handling

    private func handle(_ event: SpeechCaptureEvent) {
        switch event {
        case .partial(let text):
            partial = processor.process(text)
        case .finalizedSegment(let text):
            commitParagraph(text)
            partial = ""
        case .level(let value):
            // Simple smoothing so bars glide rather than jump.
            level = level * 0.6 + value * 0.4
        case .failure(let error):
            phase = .denied(DeniedReason(error))
            level = 0
        }
    }

    private func commitParagraph(_ text: String) {
        let processed = processor.process(text)
        let trimmed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        paragraphs.append(trimmed)
    }
}
