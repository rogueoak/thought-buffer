import SwiftUI

/// The in-app launch cover (spec 0012): the app icon centered on the River Mist background with a
/// row of waveform / equalizer bars beneath it that rise and fall as if reacting to a voice. iOS's
/// system launch screen is a static image shown before app code runs and cannot be animated, so this
/// is presented by the SwiftUI root first and then cross-faded away.
///
/// Pure visual: no mic, no audio, no dependencies. The bar heights are a phase-shifted sine of the
/// timeline date, computed by the testable static `barHeight(bar:of:at:)`. Reduce Motion swaps the
/// animation for a static-but-varied row.
struct LaunchCoverView: View {
    /// Called when the cover should dismiss because it was tapped (tap-to-skip). The gate in
    /// `ThoughtBufferApp` also dismisses on its own hold timer, so this closure is only the early-out.
    let onSkip: () -> Void

    /// Number of waveform bars. A named constant so it is easy to tune.
    static let barCount = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            CanopyColor.bg.ignoresSafeArea()

            VStack(spacing: CanopySpacing.x8) {
                // Title and tagline sit together (feedback 0028): the tagline reads directly under
                // the wordmark, so they share a tight inner stack while the x8 spacing keeps the
                // pair clear of the icon below.
                VStack(spacing: CanopySpacing.x2) {
                    Text("Thought Buffer")
                        .font(.system(size: CanopyFont.sizeX3xl, weight: .bold))
                        .foregroundStyle(CanopyColor.text)
                        .multilineTextAlignment(.center)

                    Text("Capture your thoughts, hands free")
                        .font(.system(size: CanopyFont.sizeBase))
                        .foregroundStyle(CanopyColor.textMuted)
                        .multilineTextAlignment(.center)
                }

                // Borderless logo that melts into the backdrop (feedback 0019): no clip shape or
                // outline, and a soft radial mask fades the edges into the launch background so the
                // icon reads as part of the backdrop rather than a crisp tile sitting on top.
                Image("LaunchIcon")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: iconSize, height: iconSize)
                    .mask(logoFadeMask)
                    .accessibilityHidden(true)

                bars
                    .frame(height: barRowHeight)
                    .accessibilityHidden(true)
            }
        }
        // A full-screen, borderless tap target so tapping anywhere skips the cover.
        .contentShape(Rectangle())
        .onTapGesture(perform: onSkip)
    }

    @ViewBuilder
    private var bars: some View {
        if reduceMotion {
            // Reduce Motion: a static but varied row (sampled once at a fixed instant), never animating.
            barRow { bar in
                LaunchCoverView.barHeight(bar: bar, of: LaunchCoverView.barCount, at: 0)
            }
        } else {
            // `.animation` drives a redraw every frame; each bar's height rides a phase-shifted sine of
            // the timeline date so the row ripples like speech.
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                barRow { bar in
                    LaunchCoverView.barHeight(bar: bar, of: LaunchCoverView.barCount, at: t)
                }
            }
        }
    }

    /// A row of bars whose normalized 0...1 heights come from `height(_:)`.
    private func barRow(_ height: @escaping (Int) -> Double) -> some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(0..<LaunchCoverView.barCount, id: \.self) { bar in
                Capsule()
                    .fill(CanopyColor.primary)
                    .frame(width: barWidth, height: barHeight(normalized: height(bar)))
            }
        }
    }

    /// A soft radial mask so the logo fades into the launch background at its edges rather than
    /// sitting on top with a hard boundary (feedback 0019). Solid through the center, fully
    /// transparent by the corners.
    private var logoFadeMask: some View {
        RadialGradient(
            gradient: Gradient(stops: [
                .init(color: .white, location: 0),
                .init(color: .white, location: 0.6),
                .init(color: .clear, location: 1)
            ]),
            center: .center,
            startRadius: 0,
            endRadius: iconSize / 2
        )
    }

    private let iconSize: CGFloat = 120
    /// Waveform bar width. Named so it is tunable; thinner than before (feedback 0019) so the row
    /// reads as a finer, logo-like waveform.
    private let barWidth: CGFloat = CanopySpacing.x1
    /// Gap between bars, tightened alongside the thinner bars so the row stays a cohesive waveform.
    private let barSpacing: CGFloat = CanopySpacing.x1_5
    private let barRowHeight: CGFloat = CanopySpacing.x16
    private let minBarHeight: CGFloat = CanopySpacing.x2

    /// Map a normalized 0...1 height to a point height within the bar row, keeping a visible floor so
    /// no bar collapses to nothing.
    private func barHeight(normalized: Double) -> CGFloat {
        LaunchCoverView.barPointHeight(normalized: normalized, floor: minBarHeight, rowHeight: barRowHeight)
    }

    /// The pure, testable normalized-to-point mapping (tester review): clamps to 0...1 and keeps a
    /// `floor` so no bar collapses to nothing. Static so the clamp + floor guarantee is unit-testable.
    static func barPointHeight(normalized: Double, floor: CGFloat, rowHeight: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, normalized))
        return floor + (rowHeight - floor) * CGFloat(clamped)
    }

    /// The pure, testable bar-height math: a normalized 0...1 height for `bar` (of `count` bars) at
    /// time `t` (seconds). Each bar rides a sine phase-shifted by its index so the row is never flat
    /// and ripples over time like speech. Two frequencies are summed so the motion does not read as a
    /// single sweeping wave.
    static func barHeight(bar: Int, of count: Int, at t: Double) -> Double {
        // Reverse the traveling-wave direction (feedback 0018): index the phase from the far end so
        // the crest sweeps the opposite way. Bar 0 uses the largest offset, the last bar uses zero.
        let index = Double(count - 1 - bar)
        // Phase offset per bar so neighbours differ at any instant (the row is not flat).
        let phase = index * 0.9
        let primaryWave = sin(t * 3.1 + phase)
        let secondaryWave = sin(t * 5.7 + phase * 1.7)
        // Combine and normalize into 0...1. Weighting keeps the primary wave dominant.
        let combined = (primaryWave * 0.65 + secondaryWave * 0.35)
        return (combined + 1) / 2
    }
}

#Preview {
    LaunchCoverView(onSkip: {})
}
