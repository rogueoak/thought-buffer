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
        case denied(SpeechDictationService.DictationError)
        case saved
    }

    @Published private(set) var phase: Phase = .idle
    /// Finalized paragraphs committed to the note so far.
    @Published private(set) var paragraphs: [String] = []
    /// The in-progress phrase for the current task, shown live with a caret.
    @Published private(set) var partial: String = ""
    /// Smoothed microphone level, 0...1, for the waveform.
    @Published private(set) var level: Float = 0

    private let service: SpeechDictationService
    private let store: NoteStore
    private let createdAt = Date()
    private let noteID = UUID()

    init(service: SpeechDictationService = SpeechDictationService(), store: NoteStore = NoteStore()) {
        self.service = service
        self.store = store
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
            phase = .denied(authError)
            return
        }
        if let availError = service.availabilityError() {
            phase = .denied(availError)
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
    @discardableResult
    func finish() -> Note? {
        service.stop()
        // Fold any live partial into the committed paragraphs before saving.
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            paragraphs.append(trimmed)
            partial = ""
        }
        phase = .saved
        level = 0

        guard !paragraphs.isEmpty else { return nil }

        let title = Note.deriveTitle(paragraphs: paragraphs, createdAt: createdAt)
        let note = Note(id: noteID, title: title, paragraphs: paragraphs, createdAt: createdAt)
        try? store.save(note)
        return note
    }

    /// Discard the session without saving (used when the user backs out empty).
    func cancel() {
        service.stop()
        level = 0
    }

    /// Inject text as if it had been dictated. Used by screenshot tooling and by tests to prove
    /// the save flow without live audio in the simulator.
    func injectFinalized(_ text: String) {
        commitParagraph(text)
    }

    // MARK: - Event handling

    private func handle(_ event: SpeechDictationService.Event) {
        switch event {
        case .partial(let text):
            partial = text
        case .finalizedSegment(let text):
            commitParagraph(text)
            partial = ""
        case .level(let value):
            // Simple smoothing so bars glide rather than jump.
            level = level * 0.6 + value * 0.4
        case .failure(let error):
            phase = .denied(error)
            level = 0
        }
    }

    private func commitParagraph(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        paragraphs.append(trimmed)
    }
}

// MARK: - Friendly error copy

extension SpeechDictationService.DictationError {
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

    /// A sentence or two telling the user what to do next.
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
        case .engineFailure(let message):
            return "Something went wrong starting the recorder. " + message
        }
    }
}
