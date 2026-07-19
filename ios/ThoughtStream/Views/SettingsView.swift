import SwiftUI

/// The real Settings screen (spec 0006). Edits the injected `SettingsStoring` instance directly,
/// so changes persist and are read by the composition root when it builds the next session's text
/// processor. Themed with Canopy tokens to match the app.
///
/// Two configurable features and a read-only status:
/// - the assistant control phrase (validated; empty falls back to "Mira"),
/// - an ordered list of spelling overrides (add / edit / delete), and
/// - where notes are stored (iCloud vs on this device), read-only.
///
/// Changes take effect on the NEXT dictation session, since the processor is built per session.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    private let settings: SettingsStoring
    private let storeKind: NoteStoreKind

    /// Local editing copies. Written back to the store on change so persistence is immediate and
    /// SwiftUI drives the fields without fighting the protocol's plain properties.
    @State private var controlPhrase: String
    @State private var overrides: [SpellingOverride]
    /// The chosen retention mode, plus the day count for the auto-delete mode (kept even while the
    /// mode is not auto-delete, so toggling back restores the last window instead of resetting).
    @State private var retentionMode: RetentionMode
    @State private var autoDeleteDays: Int
    /// The chosen lock-screen title mode (note title vs a fixed generic label).
    @State private var lockScreenTitle: LockScreenTitle
    /// Whether transcript refinement is on (spec 0016): filler removal live, reflow on edit-save.
    @State private var refineTranscript: Bool

    init(settings: SettingsStoring, storeKind: NoteStoreKind = .local) {
        self.settings = settings
        self.storeKind = storeKind
        _controlPhrase = State(initialValue: settings.controlPhrase)
        _overrides = State(initialValue: settings.spellingOverrides)
        let retention = settings.audioRetention
        _retentionMode = State(initialValue: RetentionMode(retention))
        _autoDeleteDays = State(initialValue: retention.autoDeleteDays ?? SettingsView.defaultAutoDeleteDays)
        _lockScreenTitle = State(initialValue: settings.lockScreenTitle)
        _refineTranscript = State(initialValue: settings.refineTranscript)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CanopyColor.bg.ignoresSafeArea()

                List {
                    assistantSection
                    refineSection
                    overridesSection
                    recordingSection
                    lockScreenSection
                    storageSection
                }
                .scrollContentBackground(.hidden)
                .foregroundStyle(CanopyColor.text)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(CanopyColor.primary)
                }
            }
        }
        .tint(CanopyColor.primary)
    }

    // MARK: - Assistant

    private var assistantSection: some View {
        Section {
            TextField("Assistant name", text: $controlPhrase)
                // A single leading token is expected, not a title-cased phrase; word-by-word
                // autocapitalization fights that, so leave capitalization to the user.
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(CanopyColor.text)
                .onChange(of: controlPhrase) { _, newValue in
                    settings.controlPhrase = newValue
                }
        } header: {
            Text("Assistant")
                .foregroundStyle(CanopyColor.textMuted)
        } footer: {
            VStack(alignment: .leading, spacing: CanopySpacing.x1) {
                Text("Say this word before a command, like \"\(effectiveControlPhrase) new note\".")
                Text("Leave it blank to use \"\(ControlPhrase.defaultWord)\". Changes apply to your next session.")
            }
            .font(.system(size: CanopyFont.sizeXs))
            .foregroundStyle(CanopyColor.textSubtle)
        }
    }

    /// What the control phrase actually resolves to (blank or multi-word collapses via the shared
    /// `ControlPhrase` seam), so the hint stays honest while the field is edited - without the view
    /// depending on any concrete store.
    private var effectiveControlPhrase: String {
        ControlPhrase.validated(controlPhrase)
    }

    // MARK: - Refine transcript (spec 0016)

    private var refineSection: some View {
        Section {
            Toggle("Refine transcript", isOn: $refineTranscript)
                .foregroundStyle(CanopyColor.text)
                .tint(CanopyColor.primary)
                .onChange(of: refineTranscript) { _, newValue in
                    settings.refineTranscript = newValue
                }
        } header: {
            Text("Transcript")
                .foregroundStyle(CanopyColor.textMuted)
        } footer: {
            Text("Removes filler words (\"um\", \"uh\") and tidies sentences when you save an edit. "
                + "Your audio is never changed. Changes apply to your next session.")
                .font(.system(size: CanopyFont.sizeXs))
                .foregroundStyle(CanopyColor.textSubtle)
        }
    }

    // MARK: - Spelling overrides

    private var overridesSection: some View {
        Section {
            ForEach($overrides) { $override in
                OverrideRow(override: $override)
                    .onChange(of: override) { _, _ in persistOverrides() }
            }
            .onDelete(perform: deleteOverrides)

            Button {
                overrides.append(SpellingOverride(from: "", to: ""))
                persistOverrides()
            } label: {
                Label("Add override", systemImage: "plus.circle")
                    .foregroundStyle(CanopyColor.primary)
            }
        } header: {
            Text("Spelling overrides")
                .foregroundStyle(CanopyColor.textMuted)
        } footer: {
            Text("Auto-replace words the app hears wrong. Whole words only, any capitalization. For example, spoken \"Shay\" becomes written \"Shea\".")
                .font(.system(size: CanopyFont.sizeXs))
                .foregroundStyle(CanopyColor.textSubtle)
        }
    }

    private func deleteOverrides(at offsets: IndexSet) {
        overrides.remove(atOffsets: offsets)
        persistOverrides()
    }

    private func persistOverrides() {
        settings.spellingOverrides = overrides
    }

    // MARK: - Recording (spec 0007)

    /// The default auto-delete window offered when the user first picks that mode.
    static let defaultAutoDeleteDays = 30

    /// The retention modes as a flat, pickable set (the associated `days` of the enum lives in a
    /// separate stepper so the picker stays simple).
    enum RetentionMode: String, CaseIterable, Identifiable {
        case keep
        case transcriptOnly
        case autoDelete

        var id: String { rawValue }

        init(_ retention: AudioRetention) {
            switch retention {
            case .keep: self = .keep
            case .transcriptOnly: self = .transcriptOnly
            case .autoDeleteDays: self = .autoDelete
            }
        }

        var label: String {
            switch self {
            case .keep: return "Keep recordings"
            case .transcriptOnly: return "Transcript only"
            case .autoDelete: return "Auto-delete"
            }
        }
    }

    private var recordingSection: some View {
        Section {
            Picker("Recordings", selection: $retentionMode) {
                ForEach(RetentionMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .onChange(of: retentionMode) { _, _ in persistRetention() }

            if retentionMode == .autoDelete {
                Stepper(value: $autoDeleteDays, in: AudioRetention.minDays...AudioRetention.maxDays) {
                    Text("Delete after \(autoDeleteDays) day\(autoDeleteDays == 1 ? "" : "s")")
                        .foregroundStyle(CanopyColor.text)
                }
                .onChange(of: autoDeleteDays) { _, _ in persistRetention() }
            }
        } header: {
            Text("Voice recordings")
                .foregroundStyle(CanopyColor.textMuted)
        } footer: {
            Text("Keep the audio of each note (default), record the transcript only, or delete "
                + "recordings automatically after a while. Audio stays on your device (or your "
                + "iCloud, if enabled) and is never uploaded to us.")
                .font(.system(size: CanopyFont.sizeXs))
                .foregroundStyle(CanopyColor.textSubtle)
        }
    }

    /// Write the chosen retention back to the store. The day count only matters in auto-delete mode.
    private func persistRetention() {
        switch retentionMode {
        case .keep:
            settings.audioRetention = .keep
        case .transcriptOnly:
            settings.audioRetention = .transcriptOnly
        case .autoDelete:
            settings.audioRetention = .autoDeleteDays(autoDeleteDays)
        }
    }

    // MARK: - Lock screen title (spec 0008)

    /// A pickable label for each lock-screen title mode.
    private func lockScreenLabel(_ mode: LockScreenTitle) -> String {
        switch mode {
        case .noteTitle: return "Note title"
        case .generic: return "Generic label"
        }
    }

    private var lockScreenSection: some View {
        Section {
            Picker("Lock screen title", selection: $lockScreenTitle) {
                ForEach(LockScreenTitle.allCases) { mode in
                    Text(lockScreenLabel(mode)).tag(mode)
                }
            }
            .onChange(of: lockScreenTitle) { _, newValue in
                settings.lockScreenTitle = newValue
            }
        } header: {
            Text("Lock screen")
                .foregroundStyle(CanopyColor.textMuted)
        } footer: {
            Text("Show the note's title while it plays on the lock screen, Control Center, and "
                + "CarPlay, or hide it behind \"\(LockScreenTitle.genericTitle)\" so a sensitive "
                + "first line stays private.")
                .font(.system(size: CanopyFont.sizeXs))
                .foregroundStyle(CanopyColor.textSubtle)
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section {
            LabeledContent("Location", value: storageLabel)
            // Driven from the store's own format constant rather than a bare literal, so the row
            // stays truthful if the on-disk format ever changes.
            LabeledContent("Format", value: NoteStore.storageFormatLabel)
        } header: {
            Text("Storage")
                .foregroundStyle(CanopyColor.textMuted)
        }
    }

    private var storageLabel: String {
        switch storeKind {
        case .iCloud: return "iCloud"
        case .local: return "On this device"
        }
    }
}

/// One editable spelling-override row: the spoken word on the left, the correction on the right.
private struct OverrideRow: View {
    @Binding var override: SpellingOverride

    var body: some View {
        HStack(spacing: CanopySpacing.x2) {
            TextField("Heard", text: $override.from)
                .autocorrectionDisabled()
                .foregroundStyle(CanopyColor.text)
            Image(systemName: "arrow.right")
                .font(.system(size: CanopyFont.sizeXs))
                .foregroundStyle(CanopyColor.textMuted)
            TextField("Written", text: $override.to)
                .autocorrectionDisabled()
                .foregroundStyle(CanopyColor.text)
        }
    }
}

#Preview {
    SettingsView(
        settings: UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: "preview")!),
        storeKind: .local
    )
}
