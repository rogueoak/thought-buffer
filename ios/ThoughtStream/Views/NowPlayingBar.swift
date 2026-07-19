import SwiftUI

/// A compact now-playing bar (spec 0015) bound to the ONE shared `ThoughtPlaybackController`, shown above
/// the Record button on every folder screen while something plays from the list. It renders the
/// current recording's title, a play/pause toggle, a stop button, and - only while a queue has a next
/// item - a Next button. Tapping the title opens that thought.
///
/// It observes the shared controller directly (the controller publishes `currentThought`, `isPlaying`,
/// and `hasNext`), so it appears when a swipe starts playback, updates its title as a queue advances,
/// and hides the instant playback stops or the queue ends - no second audio path, no second Now
/// Playing writer. The controller is optional so a screenshot / preview build with no shared
/// controller simply shows nothing.
struct NowPlayingBar: View {
    @ObservedObject var controller: ThoughtPlaybackController
    /// Route to the tapped thought's detail page, wired by the host to append `.thought(currentThought)` to the
    /// navigation path.
    let onOpenThought: (Thought) -> Void

    var body: some View {
        // Shown only while a recording is loaded; otherwise the bar collapses to nothing so the Record
        // button sits alone.
        if let thought = controller.currentThought {
            HStack(spacing: CanopySpacing.x3) {
                Button {
                    onOpenThought(thought)
                } label: {
                    HStack(spacing: CanopySpacing.x2) {
                        Image(systemName: "waveform")
                            .font(.system(size: CanopyFont.sizeBase, weight: .semibold))
                            .foregroundStyle(CanopyColor.primary)
                        Text(controller.currentTitle ?? thought.title)
                            .font(.system(size: CanopyFont.sizeSm, weight: .semibold))
                            .foregroundStyle(CanopyColor.text)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Now playing: \(controller.currentTitle ?? thought.title)")

                Button {
                    controller.togglePlayPause()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: CanopyFont.sizeBase, weight: .semibold))
                        .foregroundStyle(CanopyColor.primary)
                }
                .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

                if controller.hasNext {
                    Button {
                        controller.playNext()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: CanopyFont.sizeBase, weight: .semibold))
                            .foregroundStyle(CanopyColor.primary)
                    }
                    .accessibilityLabel("Next")
                }

                Button {
                    controller.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: CanopyFont.sizeBase, weight: .semibold))
                        .foregroundStyle(CanopyColor.textSubtle)
                }
                .accessibilityLabel("Stop")
            }
            .padding(.horizontal, CanopySpacing.x4)
            .padding(.vertical, CanopySpacing.x3)
            .background(CanopyColor.surface)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(CanopyColor.border, lineWidth: 1)
            )
            .shadow(color: CanopyColor.overlay.opacity(0.2), radius: 12, y: 6)
            .padding(.horizontal, CanopySpacing.x4)
        }
    }
}
