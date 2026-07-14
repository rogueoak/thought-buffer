import SwiftUI

/// Live-capture screen. Requests permission, streams on-device speech into a note through
/// `DictationViewModel`, shows finalized paragraphs plus the in-progress partial with a
/// blinking caret, and drives the waveform from the real microphone level. Stopping saves the
/// note and hands it back to the caller.
struct DictationView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: DictationViewModel

    /// Called with the saved note (or nil when nothing was captured) as the screen dismisses.
    private let onFinish: (Note?) -> Void

    /// Sample text injected in preview / screenshot mode so the design renders without a mic.
    private let previewInjection: String?

    /// A command phrase injected after `previewInjection` in screenshot mode, so the command chip
    /// renders without a mic. Fired once on appear.
    private let previewCommand: String?

    @State private var caretVisible = true
    private let caretTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    /// Set when saving the note fails, so the screen surfaces an alert instead of reporting the
    /// note as saved and dismissing.
    @State private var showSaveError = false

    /// Whether the command cheat-sheet drawer is up (feedback 0008).
    @State private var showCheatSheet = false

    /// Keyboard editing of the paused transcript (feedback 0008): whether the transcript is being
    /// edited, and the working text while it is. Editing is offered only when capture is paused, so a
    /// moving cursor never fights the incoming stream.
    @State private var isEditingTranscript = false
    @State private var draftTranscript = ""
    @FocusState private var transcriptEditorFocused: Bool

    /// Build the screen from an explicit view model. Callers wire the model (and thus its note
    /// store) from the composition root; see `StreamListView`.
    init(
        model: DictationViewModel,
        previewInjection: String? = nil,
        previewCommand: String? = nil,
        onFinish: @escaping (Note?) -> Void = { _ in }
    ) {
        _model = StateObject(wrappedValue: model)
        self.previewInjection = previewInjection
        self.previewCommand = previewCommand
        self.onFinish = onFinish
    }

    var body: some View {
        ZStack {
            CanopyColor.bg.ignoresSafeArea()

            VStack(spacing: CanopySpacing.x5) {
                header

                switch model.phase {
                case .denied(let error):
                    Spacer(minLength: 0)
                    deniedCard(error)
                    Spacer(minLength: 0)
                default:
                    liveCard

                    Waveform(level: model.isRecording ? CGFloat(model.level) : 0)
                        .frame(height: 44)
                        .padding(.horizontal, CanopySpacing.x4)

                    if let error = model.commandError {
                        commandErrorChip(error)
                            .transition(.opacity)
                    } else if let banner = model.commandBanner {
                        commandChip(banner)
                            .transition(.opacity)
                    } else {
                        statusChip
                    }

                    Spacer(minLength: 0)

                    Dock(
                        isPaused: model.phase == .paused,
                        onPause: {
                            // Resuming/pausing commits any in-progress edit first, so hand-typed text
                            // is never lost when the stream starts again.
                            commitTranscriptEdit()
                            model.togglePause()
                        },
                        onStop: finish,
                        onCheatSheet: { showCheatSheet = true }
                    )
                }
            }
            .padding(.top, CanopySpacing.x4)
            .padding(.bottom, CanopySpacing.x6)
        }
        .animation(.easeInOut(duration: 0.2), value: model.commandBanner)
        .animation(.easeInOut(duration: 0.2), value: model.commandError)
        .onReceive(caretTimer) { _ in caretVisible.toggle() }
        .alert("Could not save your note", isPresented: $showSaveError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Something went wrong writing the note to your device. Your words are still on "
                + "screen. Tap Stop to try saving again.")
        }
        .sheet(isPresented: $showCheatSheet) {
            CommandCheatSheet(controlWord: model.controlWord)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task {
            if let injection = previewInjection {
                model.injectFinalized(injection)
                if let command = previewCommand {
                    model.injectFinalized(command)
                }
            } else {
                await model.begin()
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                model.cancel()
                onFinish(nil)
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: CanopyFont.sizeLg, weight: .semibold))
                    .foregroundStyle(CanopyColor.textMuted)
            }
            Spacer()
            Text("Live")
                .font(.system(size: CanopyFont.sizeSm, weight: .semibold))
                .foregroundStyle(CanopyColor.text)
            Spacer()
            // Balance the leading chevron so the title stays centered.
            Image(systemName: "chevron.down").opacity(0)
        }
        .padding(.horizontal, CanopySpacing.x4)
    }

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: CanopySpacing.x3) {
            HStack(spacing: CanopySpacing.x2) {
                Circle()
                    .fill(model.phase == .paused ? CanopyColor.textSubtle : CanopyColor.danger)
                    .frame(width: 8, height: 8)
                Text(model.phase == .paused ? "Paused" : "Recording")
                    .font(.system(size: CanopyFont.sizeXs, weight: .semibold))
                    .foregroundStyle(CanopyColor.textSubtle)
                Spacer(minLength: 0)
                // Keyboard editing is offered only while paused (feedback 0008). Tapping Edit swaps
                // the transcript for a text editor seeded with the current text; Done commits it.
                if model.phase == .paused && !model.isEmpty {
                    Button(isEditingTranscript ? "Done" : "Edit") {
                        if isEditingTranscript {
                            commitTranscriptEdit()
                        } else {
                            beginTranscriptEdit()
                        }
                    }
                    .font(.system(size: CanopyFont.sizeXs, weight: .semibold))
                    .foregroundStyle(CanopyColor.primary)
                }
            }

            if isEditingTranscript {
                TextEditor(text: $draftTranscript)
                    .focused($transcriptEditorFocused)
                    .font(.system(size: CanopyFont.sizeLg))
                    .foregroundStyle(CanopyColor.text)
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Auto-scroll to the newest text as it streams in (feedback 0008): the transcript
                // follows the live caret so the most recent words stay in view while recording.
                ScrollViewReader { proxy in
                    ScrollView {
                        transcript
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // A zero-height anchor pinned below the text; scrolling to it keeps the bottom
                        // (the live partial) visible as content grows.
                        Color.clear
                            .frame(height: 1)
                            .id(Self.transcriptBottomID)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: model.partial) { _, _ in scrollToBottom(proxy) }
                    .onChange(of: model.paragraphs.count) { _, _ in scrollToBottom(proxy) }
                }
            }
        }
        .padding(CanopySpacing.x5)
        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 320, alignment: .topLeading)
        .background(CanopyColor.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: CanopyRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CanopyRadius.xl, style: .continuous)
                .stroke(CanopyColor.border, lineWidth: 1)
        )
        .padding(.horizontal, CanopySpacing.x4)
    }

    @ViewBuilder
    private var transcript: some View {
        if model.isEmpty {
            Text("Listening... start talking and your words appear here.")
                .font(.system(size: CanopyFont.sizeLg))
                .foregroundStyle(CanopyColor.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: CanopySpacing.x3) {
                let paragraphs = model.displayParagraphs
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                    if index == paragraphs.count - 1 {
                        // The last paragraph carries the live caret.
                        (
                            Text(paragraph + " ")
                                .foregroundColor(CanopyColor.text)
                                + Text("|")
                                .foregroundColor(caretVisible ? CanopyColor.primary : .clear)
                        )
                        .font(.system(size: CanopyFont.sizeLg))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(paragraph)
                            .font(.system(size: CanopyFont.sizeLg))
                            .foregroundColor(CanopyColor.text)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var statusChip: some View {
        HStack(spacing: CanopySpacing.x2) {
            Image(systemName: model.phase == .paused ? "pause.circle" : "waveform")
            Text(model.phase == .paused ? "Paused - tap play to keep going" : "On-device - nothing leaves your phone")
        }
        .font(.system(size: CanopyFont.sizeSm))
        .foregroundStyle(CanopyColor.mutedForeground)
        .padding(.horizontal, CanopySpacing.x4)
        .padding(.vertical, CanopySpacing.x2)
        .background(CanopyColor.muted)
        .clipShape(Capsule())
    }

    /// The transient control chip shown when a Mira command fires, in the muted token style. The
    /// full label (e.g. "Mira - removed last sentence") is assembled in the view model, where the
    /// active control word is known, so it stays correct once the control word is configurable.
    private func commandChip(_ label: String) -> some View {
        HStack(spacing: CanopySpacing.x2) {
            Image(systemName: "wand.and.stars")
            Text(label)
                .font(.system(size: CanopyFont.sizeSm, weight: .semibold))
        }
        .font(.system(size: CanopyFont.sizeSm))
        .foregroundStyle(CanopyColor.mutedForeground)
        .padding(.horizontal, CanopySpacing.x4)
        .padding(.vertical, CanopySpacing.x2)
        .background(CanopyColor.muted)
        .clipShape(Capsule())
    }

    /// The chip shown when a voice command could not complete (e.g. "new note" failed to save), so
    /// the user sees the failure instead of a false success. Uses the danger accent.
    private func commandErrorChip(_ error: DictationViewModel.CommandError) -> some View {
        HStack(spacing: CanopySpacing.x2) {
            Image(systemName: "exclamationmark.triangle")
            Text(commandErrorLabel(error))
                .font(.system(size: CanopyFont.sizeSm, weight: .semibold))
        }
        .font(.system(size: CanopyFont.sizeSm))
        .foregroundStyle(CanopyColor.danger)
        .padding(.horizontal, CanopySpacing.x4)
        .padding(.vertical, CanopySpacing.x2)
        .background(CanopyColor.muted)
        .clipShape(Capsule())
    }

    private func commandErrorLabel(_ error: DictationViewModel.CommandError) -> String {
        switch error {
        case .newNoteSaveFailed:
            return "Could not save - note kept"
        }
    }

    private func deniedCard(_ error: DictationViewModel.DeniedReason) -> some View {
        VStack(spacing: CanopySpacing.x3) {
            Image(systemName: "mic.slash")
                .font(.system(size: CanopyFont.sizeX3xl, weight: .semibold))
                .foregroundStyle(CanopyColor.danger)
            Text(error.headline)
                .font(.system(size: CanopyFont.sizeXl, weight: .semibold))
                .foregroundStyle(CanopyColor.text)
                .multilineTextAlignment(.center)
            Text(error.detail)
                .font(.system(size: CanopyFont.sizeSm))
                .foregroundStyle(CanopyColor.textMuted)
                .multilineTextAlignment(.center)
            Button {
                onFinish(nil)
                dismiss()
            } label: {
                Text("Close")
                    .font(.system(size: CanopyFont.sizeBase, weight: .semibold))
                    .foregroundStyle(CanopyColor.primaryForeground)
                    .padding(.horizontal, CanopySpacing.x6)
                    .padding(.vertical, CanopySpacing.x3)
                    .background(CanopyColor.primary)
                    .clipShape(Capsule())
            }
            .padding(.top, CanopySpacing.x2)
        }
        .padding(CanopySpacing.x6)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, CanopySpacing.x4)
    }

    /// The id of the zero-height anchor at the bottom of the transcript, used to auto-scroll.
    private static let transcriptBottomID = "transcript-bottom"

    /// Keep the newest text in view as it streams in.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(Self.transcriptBottomID, anchor: .bottom)
        }
    }

    /// Enter transcript edit mode, seeding the editor with the current transcript text.
    private func beginTranscriptEdit() {
        draftTranscript = model.editableTranscript
        isEditingTranscript = true
        transcriptEditorFocused = true
    }

    /// Commit an in-progress transcript edit back into the model, then leave edit mode. A no-op when
    /// not editing, so it is safe to call from Pause/Resume/Stop unconditionally.
    private func commitTranscriptEdit() {
        guard isEditingTranscript else { return }
        model.applyEditedTranscript(draftTranscript)
        isEditingTranscript = false
        transcriptEditorFocused = false
    }

    private func finish() {
        // Fold any hand-typed edit into the model before saving so it is included in the note.
        commitTranscriptEdit()
        do {
            let note = try model.finish()
            onFinish(note)
            dismiss()
        } catch {
            // Saving failed: keep the screen up with the transcript intact and surface an alert
            // instead of reporting success.
            showSaveError = true
        }
    }
}

/// An audio-reactive waveform row: vertical bars whose height rides the live mic `level`,
/// with a per-bar shape so the row still reads as a waveform when the level is steady.
private struct Waveform: View {
    /// Current mic level, 0...1. Zero when paused or idle.
    let level: CGFloat
    private let bars = 28

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: CanopySpacing.x1) {
                ForEach(0..<bars, id: \.self) { index in
                    Capsule()
                        .fill(CanopyColor.primary)
                        .frame(height: barHeight(index: index, maxHeight: proxy.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.12), value: level)
        }
    }

    private func barHeight(index: Int, maxHeight: CGFloat) -> CGFloat {
        // Clamp the inputs so a non-finite or negative value can never reach a frame height
        // (SwiftUI logs "Invalid frame dimension" for NaN/negative). `maxHeight` can be 0 on the
        // first layout pass, and `level` is derived from live audio, so guard both.
        let available = (maxHeight.isFinite && maxHeight > 0) ? maxHeight : 0
        let safeLevel = level.isFinite ? min(1, max(0, level)) : 0
        // A stable pseudo-wave shape (0...1) scaled by the live level.
        let shape = (sin(Double(index) * 0.7) + 1) / 2
        let floor = 0.12
        let factor = floor + (shape * 0.35 + 0.65) * Double(safeLevel) * (1 - floor)
        return max(4, available * CGFloat(min(1, factor)))
    }
}

/// The bottom dock: Pause/Resume | big circular Stop button | Commands. Stop saves and closes; the
/// Commands button (feedback 0008) opens the cheat-sheet drawer and balances the leading control so
/// the stop button stays centered.
private struct Dock: View {
    let isPaused: Bool
    let onPause: () -> Void
    let onStop: () -> Void
    let onCheatSheet: () -> Void

    var body: some View {
        HStack {
            dockButton(
                title: isPaused ? "Resume" : "Pause",
                system: isPaused ? "play.fill" : "pause.fill",
                action: onPause
            )
            Spacer()
            stopButton
            Spacer()
            dockButton(title: "Commands", system: "questionmark.circle", action: onCheatSheet)
                .accessibilityLabel("Show voice commands")
        }
        .padding(.horizontal, CanopySpacing.x8)
    }

    private var stopButton: some View {
        Button(action: onStop) {
            ZStack {
                Circle()
                    .fill(CanopyColor.primary)
                    .frame(width: 76, height: 76)
                    .shadow(color: CanopyColor.overlay.opacity(0.3), radius: 14, y: 6)
                Image(systemName: "stop.fill")
                    .font(.system(size: CanopyFont.sizeX2xl, weight: .semibold))
                    .foregroundStyle(CanopyColor.primaryForeground)
            }
        }
        .accessibilityLabel("Stop and save")
    }

    private func dockButton(
        title: String,
        system: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: CanopySpacing.x1) {
                Image(systemName: system.isEmpty ? "circle" : system)
                    .font(.system(size: CanopyFont.sizeXl))
                Text(title)
                    .font(.system(size: CanopyFont.sizeXs))
            }
            .foregroundStyle(CanopyColor.textMuted)
            .frame(width: 64)
        }
    }
}

/// The command cheat sheet shown in a bottom drawer from the record screen (feedback 0008): the
/// active control word, each voice command with what it does, and a tip on pausing. Content is
/// sourced from `MiraCommand.cheatSheet` so it stays in sync with the parser's grammar.
struct CommandCheatSheet: View {
    let controlWord: String

    var body: some View {
        ZStack {
            CanopyColor.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: CanopySpacing.x4) {
                    Text("Voice commands")
                        .font(.system(size: CanopyFont.sizeXl, weight: .bold))
                        .foregroundStyle(CanopyColor.text)
                    Text("Say \"\(controlWord)\" then a command. It runs the action instead of being "
                        + "written into your note.")
                        .font(.system(size: CanopyFont.sizeSm))
                        .foregroundStyle(CanopyColor.textMuted)

                    VStack(spacing: CanopySpacing.x2) {
                        ForEach(Array(MiraCommand.cheatSheet.enumerated()), id: \.offset) { _, command in
                            commandRow(phrase: "\(controlWord) \(command.spokenPhrase)",
                                       detail: command.cheatSheetDetail)
                        }
                        commandRow(phrase: "Pause to think",
                                   detail: "Stop talking for a moment to end a paragraph; keep going "
                                       + "and your words continue in a new one.")
                    }
                }
                .padding(CanopySpacing.x5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func commandRow(phrase: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: CanopySpacing.x1) {
            Text(phrase)
                .font(.system(size: CanopyFont.sizeBase, weight: .semibold))
                .foregroundStyle(CanopyColor.text)
            Text(detail)
                .font(.system(size: CanopyFont.sizeSm))
                .foregroundStyle(CanopyColor.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CanopySpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CanopyColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: CanopyRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CanopyRadius.lg, style: .continuous)
                .stroke(CanopyColor.border, lineWidth: 1)
        )
    }
}

#Preview {
    DictationView(
        model: DictationViewModel(store: NoteStore()),
        previewInjection:
            "Remember to call the supplier about the Shea butter order before noon. "
                + "Then draft the launch email and keep it to three short paragraphs."
    )
}
