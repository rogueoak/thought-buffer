import SwiftUI

@main
struct ThoughtStreamApp: App {
    /// Resolved once at launch: picks iCloud storage when the ubiquity container is available and
    /// falls back to local otherwise. Held as state because resolution is async (the container
    /// lookup can block, so it runs off the main actor). Until it resolves, the screen shows the
    /// themed background, then roots to the Stream list.
    @State private var dependencies: AppDependencies?

    /// Whether the animated launch cover (spec 0012) is still up. Shown once per cold launch on
    /// normal launches only; a `.task` holds it for `launchCoverHold` then cross-fades it out, and a
    /// tap skips it early. Screenshot (`-uiScreen`) launches never show it (see `content`).
    @State private var showLaunchCover = true

    /// Minimum time the launch cover stays up before it auto-dismisses. Dependency resolution is fast
    /// and the cover sits above the pre-resolution themed background, so a plain minimum hold is
    /// enough - the cover covers the whole storage-resolution flash. A named constant so it is easy
    /// to tune.
    private static let launchCoverHold: Duration = .milliseconds(2500)

    /// True for screenshot / tooling launches, which must render with NO cover so automated captures
    /// are unaffected.
    private var isScreenshotLaunch: Bool {
        CommandLine.arguments.contains("-uiScreen")
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                content
                    .task {
                        guard dependencies == nil else { return }
                        dependencies = await AppDependencies.resolve()
                    }

                // The cover overlays everything (including the `dependencies == nil` themed-background
                // state) on normal launches, so there is no visible flash/pop before it. Skipped for
                // screenshot launches.
                if showLaunchCover && !isScreenshotLaunch {
                    LaunchCoverView(onSkip: dismissLaunchCover)
                        .transition(.opacity)
                        .zIndex(1)
                        .task {
                            try? await Task.sleep(for: Self.launchCoverHold)
                            dismissLaunchCover()
                        }
                }
            }
        }
    }

    /// Cross-fade the launch cover away. Safe to call more than once (tap-to-skip plus the hold
    /// timer): once `showLaunchCover` is false, subsequent calls are no-ops.
    private func dismissLaunchCover() {
        guard showLaunchCover else { return }
        withAnimation(.easeOut(duration: 0.4)) {
            showLaunchCover = false
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
                    sessionRoute: dependencies.sessionRoute,
                    playbackController: dependencies.playbackController
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
    var lockScreenTitle: LockScreenTitle = .noteTitle
    var noteSortOrder: NoteSortOrder = .newest
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
    func pause() {}
    func resume() -> Bool { false }
    func stop() {}
    var currentTime: Double { 0 }
    func seek(to time: Double) {}
}

/// A resolver that always returns a fixed URL, for screenshot mode: the Play affordance renders
/// without reaching into a real store.
private struct FixedAudioURLResolver: AudioURLResolving {
    let url: URL?
    func resolveAudioURL(for noteID: UUID, audioFileName: String?) -> URL? { url }
}
