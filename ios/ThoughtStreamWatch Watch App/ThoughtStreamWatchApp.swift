import SwiftUI

/// The watchOS app entry point (spec 0023). A TabView pairs the two surfaces the spec scopes:
/// quick-capture (record a voice thought from the wrist) and browse (recent thoughts pushed from the
/// phone, tap to read + play). The watch never transcribes - capture syncs to the phone, which does.
@main
struct ThoughtStreamWatchApp: App {
    @StateObject private var connectivity = WatchConnectivityManager.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(connectivity)
                .task {
                    connectivity.start()
                }
        }
    }
}

/// The two-tab root: Capture and Browse.
struct WatchRootView: View {
    var body: some View {
        TabView {
            WatchCaptureView()
                .tabItem { Text("Capture") }
            WatchBrowseView()
                .tabItem { Text("Recent") }
        }
        .tabViewStyle(.verticalPage)
    }
}
