import SwiftUI

@main
struct ThoughtStreamApp: App {
    var body: some Scene {
        WindowGroup {
            // A launch argument lets tooling open the dictation screen directly for
            // screenshots, since the simulator has no scripted tap. Normal launches
            // start on the Stream list.
            if CommandLine.arguments.contains("-uiScreen") ,
               CommandLine.arguments.contains("dictation") {
                // Screenshot mode: inject sample text so the live design renders without a mic
                // or permission prompt in the simulator.
                DictationView(previewInjection:
                    "Remember to call the supplier about the Shea butter order before noon. "
                        + "Then draft the launch email and keep it to three short paragraphs."
                )
            } else {
                StreamListView()
            }
        }
    }
}
