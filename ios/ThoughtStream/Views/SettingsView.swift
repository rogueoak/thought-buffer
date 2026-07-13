import SwiftUI

/// Minimal settings stub. Themed placeholders only; nothing here does anything yet.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                CanopyColor.bg.ignoresSafeArea()

                List {
                    Section("Assistant") {
                        LabeledContent("Control word", value: "Mira")
                        LabeledContent("Read back", value: "On")
                    }
                    Section("Storage") {
                        LabeledContent("Location", value: "On device")
                        LabeledContent("Format", value: "Markdown")
                    }
                    Section("Appearance") {
                        LabeledContent("Theme", value: "System")
                    }
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
}

#Preview {
    SettingsView()
}
