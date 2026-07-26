import SwiftUI

/// The browse screen (spec 0023): a list of recent thoughts the phone pushed (title + preview + duration).
/// Tapping a thought opens a detail view with its text and, when it has a recording, a Play control (the
/// audio is fetched from the phone on demand). No editing / folders / search on the watch.
struct WatchBrowseView: View {
    @EnvironmentObject private var connectivity: WatchConnectivityManager

    var body: some View {
        NavigationStack {
            Group {
                if connectivity.recentThoughts.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Recent")
            .background(CanopyColor.bg.ignoresSafeArea())
        }
    }

    private var list: some View {
        List(connectivity.recentThoughts) { thought in
            NavigationLink(value: thought) {
                WatchThoughtRow(thought: thought)
            }
        }
        .navigationDestination(for: RecentThoughtProjection.self) { thought in
            WatchThoughtDetailView(thought: thought)
        }
    }

    private var emptyState: some View {
        VStack(spacing: CanopySpacing.x2) {
            Image(systemName: "waveform")
                .font(.system(size: 28))
                .foregroundStyle(CanopyColor.textSubtle)
            Text("No thoughts yet")
                .font(CanopyFont.sizeSmFont())
                .foregroundStyle(CanopyColor.textMuted)
            Text("Record on your watch or phone")
                .font(CanopyFont.sizeXsFont())
                .foregroundStyle(CanopyColor.textSubtle)
                .multilineTextAlignment(.center)
        }
        .padding(CanopySpacing.x3)
    }
}

/// A single recent-thought row: title, one-line preview, and a duration badge for a recorded thought.
struct WatchThoughtRow: View {
    let thought: RecentThoughtProjection

    var body: some View {
        VStack(alignment: .leading, spacing: CanopySpacing.x1) {
            Text(thought.title)
                .font(CanopyFont.sizeSmFont())
                .foregroundStyle(CanopyColor.text)
                .lineLimit(1)
            if !thought.preview.isEmpty {
                Text(thought.preview)
                    .font(CanopyFont.sizeXsFont())
                    .foregroundStyle(CanopyColor.textMuted)
                    .lineLimit(1)
            }
            if thought.hasAudio {
                Label(Thought.durationLabel(thought.duration), systemImage: "waveform")
                    .font(CanopyFont.sizeXsFont())
                    .foregroundStyle(CanopyColor.accent)
            }
        }
        .padding(.vertical, CanopySpacing.x0_5)
    }
}
