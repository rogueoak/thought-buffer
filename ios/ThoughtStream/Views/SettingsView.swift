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

    init(settings: SettingsStoring, storeKind: NoteStoreKind = .local) {
        self.settings = settings
        self.storeKind = storeKind
        _controlPhrase = State(initialValue: settings.controlPhrase)
        _overrides = State(initialValue: settings.spellingOverrides)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CanopyColor.bg.ignoresSafeArea()

                List {
                    assistantSection
                    overridesSection
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
