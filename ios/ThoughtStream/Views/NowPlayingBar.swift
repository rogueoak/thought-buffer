import SwiftUI

/// The persistent bottom PLAYER (spec 0027), bound to the ONE shared `ThoughtPlaybackController`, shown in
/// the bottom stack (above the search bar, below the undo chip) while something plays. It supersedes spec
/// 0015's simpler now-playing bar: a full transport with the current recording's title, a play/pause
/// toggle, skip-back / skip-forward 15s buttons, and a DRAGGABLE progress slider (elapsed vs duration)
/// that seeks, plus elapsed + remaining labels. A Next button shows only while a queue has a next item.
/// Tapping the title opens that thought.
///
/// It observes the shared controller directly (the controller publishes `currentThought`, `isPlaying`,
/// `hasNext`, `elapsed`, and `duration`), so it appears when a swipe / row / detail starts playback,
/// advances its progress live as the controller's ticker runs, updates its title as a queue advances,
/// and hides the instant playback stops or the queue ends - no second audio path, no second Now
/// Playing writer. Rendered in ONE place (`StreamBottomStack`) so compact and the iPad lifted stack both
/// get it. The controller is optional so a screenshot / preview build with no shared controller shows
/// nothing.
struct BottomPlayer: View {
    @ObservedObject var controller: ThoughtPlaybackController
    /// Route to the tapped thought's detail page, wired by the host to append `.thought(currentThought)`
    /// to the navigation path.
    let onOpenThought: (Thought) -> Void

    /// The position the user is dragging the slider to, held locally so the thumb follows the finger
    /// smoothly without the live ticker fighting it; committed to the controller as a seek when the drag
    /// begins/ends. Nil when not dragging, so the slider reads the controller's live `elapsed`.
    @State private var scrubbing: Double?

    var body: some View {
        // Shown only while a recording is loaded; otherwise the player collapses to nothing so the
        // search bar sits alone.
        if let thought = controller.currentThought {
            VStack(spacing: CanopySpacing.x2) {
                titleRow(thought: thought)
                progressRow
                transportRow
            }
            .padding(.horizontal, CanopySpacing.x4)
            .padding(.vertical, CanopySpacing.x3)
            .background(CanopyColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: CanopyRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CanopyRadius.lg, style: .continuous)
                    .stroke(CanopyColor.border, lineWidth: 1)
            )
            .shadow(color: CanopyColor.overlay.opacity(0.2), radius: 12, y: 6)
            .padding(.horizontal, CanopySpacing.x4)
        }
    }

    /// The title row: a waveform glyph + the current recording's title, tappable to open the thought.
    private func titleRow(thought: Thought) -> some View {
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
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Now playing: \(controller.currentTitle ?? thought.title)")
    }

    /// The progress row: elapsed label, a draggable slider spanning `[0, duration]` that seeks the
    /// controller, and a remaining (countdown) label. While the user drags, the slider tracks the finger
    /// (`scrubbing`) and the controller is sought on change; otherwise it reads the live `elapsed`.
    private var progressRow: some View {
        let displayed = scrubbing ?? controller.elapsed
        // A zero/absent duration would make the slider range invalid; fall back to a tiny nonzero span so
        // the control still renders (disabled-looking, at the start) rather than crashing on an empty range.
        let span = max(controller.duration, 0.001)
        return HStack(spacing: CanopySpacing.x2) {
            Text(PlaybackProgress.elapsedLabel(displayed))
                .font(.system(size: CanopyFont.sizeXs, weight: .medium))
                .foregroundStyle(CanopyColor.textSubtle)
                .monospacedDigit()
                .accessibilityHidden(true)

            Slider(
                value: Binding(
                    get: { min(displayed, span) },
                    set: { scrubbing = $0 }
                ),
                in: 0...span,
                onEditingChanged: { editing in
                    if editing {
                        // Begin dragging: hold the thumb locally.
                        scrubbing = scrubbing ?? controller.elapsed
                    } else {
                        // End dragging: commit the final position as a seek, then release the local hold.
                        if let target = scrubbing { controller.seek(to: target) }
                        scrubbing = nil
                    }
                }
            )
            .tint(CanopyColor.primary)
            .disabled(controller.duration <= 0)
            .accessibilityLabel("Playback position")
            .accessibilityValue(
                "\(PlaybackProgress.elapsedLabel(displayed)) of \(Thought.durationLabel(controller.duration))"
            )

            Text(PlaybackProgress.remainingLabel(elapsed: displayed, duration: controller.duration))
                .font(.system(size: CanopyFont.sizeXs, weight: .medium))
                .foregroundStyle(CanopyColor.textSubtle)
                .monospacedDigit()
                .accessibilityHidden(true)
        }
    }

    /// The transport row: skip-back 15s, play/pause, skip-forward 15s, an optional Next (queue), and Stop.
    private var transportRow: some View {
        HStack(spacing: CanopySpacing.x5) {
            transportButton(
                systemImage: "gobackward.15",
                label: "Skip back 15 seconds",
                color: CanopyColor.primary
            ) { controller.skip(by: -controller.skipStep) }

            transportButton(
                systemImage: controller.isPlaying ? "pause.fill" : "play.fill",
                label: controller.isPlaying ? "Pause" : "Play",
                color: CanopyColor.primary,
                size: CanopyFont.sizeXl
            ) { controller.togglePlayPause() }

            transportButton(
                systemImage: "goforward.15",
                label: "Skip forward 15 seconds",
                color: CanopyColor.primary
            ) { controller.skip(by: controller.skipStep) }

            if controller.hasNext {
                transportButton(
                    systemImage: "forward.fill",
                    label: "Next",
                    color: CanopyColor.primary
                ) { controller.playNext() }
            }

            transportButton(
                systemImage: "stop.fill",
                label: "Stop",
                color: CanopyColor.textSubtle
            ) { controller.stop() }
        }
        .frame(maxWidth: .infinity)
    }

    /// One transport button: a system-image icon with an accessible label, so every control carries its
    /// own label (spec 0027) and they share sizing / tint in one place.
    private func transportButton(
        systemImage: String,
        label: String,
        color: Color,
        size: CGFloat = CanopyFont.sizeLg,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(color)
        }
        .accessibilityLabel(label)
    }
}
