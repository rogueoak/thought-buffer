import SwiftUI

@main
struct ThoughtStreamApp: App {
    /// The single composition root: wires the concrete note store once and passes it down.
    private let dependencies = AppDependencies()

    var body: some Scene {
        WindowGroup {
            // A launch argument lets tooling open the dictation screen directly for
            // screenshots, since the simulator has no scripted tap. Normal launches
            // start on the Stream list.
            if CommandLine.arguments.contains("-uiScreen") ,
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
                    makeTextProcessor: dependencies.makeTextProcessor
                )
            }
        }
    }
}
