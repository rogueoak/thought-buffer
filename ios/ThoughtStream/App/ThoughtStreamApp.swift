import SwiftUI

@main
struct ThoughtStreamApp: App {
    /// Resolved once at launch: picks iCloud storage when the ubiquity container is available and
    /// falls back to local otherwise. Held as state because resolution is async (the container
    /// lookup can block, so it runs off the main actor). Until it resolves, the screen shows the
    /// themed background, then roots to the Stream list.
    @State private var dependencies: AppDependencies?

    var body: some Scene {
        WindowGroup {
            content
                .task {
                    guard dependencies == nil else { return }
                    dependencies = await AppDependencies.resolve()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let dependencies {
            // A launch argument lets tooling open the dictation screen directly for
            // screenshots, since the simulator has no scripted tap. Normal launches
            // start on the Stream list.
            if CommandLine.arguments.contains("-uiScreen"),
               CommandLine.arguments.contains("note-playback") {
                // Screenshot mode: a note detail carrying a recording, so the Play affordance renders
                // without a mic. The audio URL points at a bundled/temp file only so the button
                // shows; a stub player keeps it inert.
                NavigationStack {
                    NoteDetailView(
                        note: ScreenshotNotes.recorded,
                        resolver: FixedAudioURLResolver(url: URL(fileURLWithPath: "/tmp/thoughtstream-preview.m4a")),
                        player: InertAudioNotePlayer()
                    )
                }
            } else if CommandLine.arguments.contains("-uiScreen"),
               CommandLine.arguments.contains("settings") {
                // Screenshot mode: render the real Settings screen seeded with a sample control
                // phrase and overrides so the live design shows populated rows without any taps.
                SettingsView(
                    settings: ScreenshotSettings(),
                    storeKind: .local
                )
            } else if CommandLine.arguments.contains("-uiScreen"),
               CommandLine.arguments.contains("dictation") {
                // Screenshot mode: inject sample text so the live design renders without a mic
                // or permission prompt in the simulator. A `mira-command` argument also injects a
                // command so the Mira control chip renders.
                DictationView(
                    model: DictationViewModel(
                        store: dependencies.noteStore,
                        processor: dependencies.makeTextProcessor()
                    ),
                    previewInjection:
                        "Remember to call the supplier about the Shea butter order before noon. "
                            + "Then draft the launch email and keep it to three short paragraphs.",
                    previewCommand: CommandLine.arguments.contains("mira-command")
                        ? "Mira remove the last sentence"
                        : nil
                )
            } else {
                StreamListView(
                    store: dependencies.noteStore,
                    makeTextProcessor: dependencies.makeTextProcessor,
                    settingsStore: dependencies.settingsStore,
                    noteStoreKind: dependencies.noteStoreKind,
                    noteObserver: dependencies.noteObserver,
                    sessionRoute: dependencies.sessionRoute
                )
            }
        } else {
            // Brief pre-resolution state: the themed background while the storage backend is
            // chosen off the main actor.
            CanopyColor.bg.ignoresSafeArea()
        }
    }
}

/// An in-memory `SettingsStoring` seeded with sample data, used only in `-uiScreen settings`
/// screenshot mode so the Settings design renders populated without touching real defaults.
private final class ScreenshotSettings: SettingsStoring {
    var controlPhrase: String = "Nova"
    var spellingOverrides: [SpellingOverride] = [
        SpellingOverride(from: "Shay", to: "Shea"),
        SpellingOverride(from: "kwan", to: "Quan"),
    ]
    var audioRetention: AudioRetention = .keep
}

/// Sample notes for screenshot mode.
private enum ScreenshotNotes {
    /// A note that carries a recording, so the detail view shows its Play affordance.
    static let recorded = Note(
        title: "Morning drive",
        paragraphs: [
            "Remember to call the supplier about the Shea butter order before noon.",
            "Then draft the launch email and keep it to three short paragraphs.",
        ],
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        audioFileName: "preview.m4a",
        timings: [
            ParagraphTiming(start: 0, duration: 4.2),
            ParagraphTiming(start: 4.2, duration: 5.1),
        ]
    )
}

/// A no-op `AudioNotePlayer` for screenshot mode: the Play button renders without touching audio.
@MainActor
private final class InertAudioNotePlayer: AudioNotePlayer {
    var onFinish: (() -> Void)?
    func play(url: URL, from start: Double, duration: Double?) -> Bool { false }
    func stop() {}
}

/// A resolver that always returns a fixed URL, for screenshot mode: the Play affordance renders
/// without reaching into a real store.
private struct FixedAudioURLResolver: AudioURLResolving {
    let url: URL?
    func resolveAudioURL(for noteID: UUID, audioFileName: String?) -> URL? { url }
}
