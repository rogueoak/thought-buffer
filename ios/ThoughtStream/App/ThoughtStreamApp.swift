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
                DictationView()
            } else {
                StreamListView()
            }
        }
    }
}
