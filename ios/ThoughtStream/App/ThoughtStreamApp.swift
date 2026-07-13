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
