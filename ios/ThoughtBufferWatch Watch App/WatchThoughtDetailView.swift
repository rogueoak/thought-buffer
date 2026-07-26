import SwiftUI

/// A recent thought's detail on the watch (spec 0023): its title, preview text, and - when it has a
/// recording - a Play control. The audio is not stored on the watch; tapping Play requests it from the
/// phone (`requestAudio`) and plays it once it arrives. Read-only: no editing on the wrist.
struct WatchThoughtDetailView: View {
    let thought: RecentThoughtProjection

    @EnvironmentObject private var connectivity: WatchConnectivityManager
    @StateObject private var player = WatchAudioPlayer()
    @State private var isFetching = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CanopySpacing.x3) {
                Text(thought.title)
                    .font(CanopyFont.sizeLgFont())
                    .foregroundStyle(CanopyColor.text)

                if !thought.preview.isEmpty {
                    Text(thought.preview)
                        .font(CanopyFont.sizeSmFont())
                        .foregroundStyle(CanopyColor.textMuted)
                }

                if thought.hasAudio {
                    playControl
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CanopySpacing.x3)
        }
        .background(CanopyColor.bg.ignoresSafeArea())
        .navigationTitle("Thought")
        .onChange(of: connectivity.receivedAudio[thought.id]) { _, newURL in
            // The requested audio arrived from the phone: play it.
            if isFetching, let url = newURL {
                isFetching = false
                _ = player.play(url: url)
                _ = connectivity.consumeAudio(for: thought.id)
            }
        }
        .onDisappear { player.stop() }
    }

    private var playControl: some View {
        Button(action: togglePlay) {
            Label(buttonLabel, systemImage: buttonIcon)
                .font(CanopyFont.sizeBaseFont())
                .frame(maxWidth: .infinity)
        }
        .tint(CanopyColor.accent)
        .accessibilityLabel(buttonLabel)
    }

    private var buttonLabel: String {
        if player.isPlaying { return "Stop" }
        if isFetching { return "Loading..." }
        return "Play \(Thought.durationLabel(thought.duration))"
    }

    private var buttonIcon: String {
        player.isPlaying ? "stop.fill" : "play.fill"
    }

    private func togglePlay() {
        if player.isPlaying {
            player.stop()
            return
        }
        // Play a cached copy immediately if the phone already sent it; otherwise request it.
        if let url = connectivity.consumeAudio(for: thought.id) {
            _ = player.play(url: url)
        } else {
            isFetching = true
            connectivity.requestAudio(for: thought.id)
        }
    }
}
