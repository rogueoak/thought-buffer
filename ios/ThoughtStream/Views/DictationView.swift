import SwiftUI

/// Mock live-capture screen. No Speech framework, no audio, no permissions: this fakes
/// "live" dictation with a timer-driven streaming string, a blinking caret, an animated
/// waveform, a command chip, and a bottom dock. Purely visual for the themed shell.
struct DictationView: View {
    @Environment(\.dismiss) private var dismiss

    // The full sample text; we reveal it a few words at a time to fake live capture.
    private static let sampleWords = (
        "Remember to call the supplier about the Shea butter order before noon. "
            + "Then draft the launch email and keep it to three short paragraphs."
    ).split(separator: " ").map(String.init)

    @State private var revealedWordCount = 4
    @State private var caretVisible = true

    private let streamTimer = Timer.publish(every: 0.45, on: .main, in: .common).autoconnect()
    private let caretTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var streamedText: String {
        Self.sampleWords.prefix(revealedWordCount).joined(separator: " ")
    }

    var body: some View {
        ZStack {
            CanopyColor.bg.ignoresSafeArea()

            VStack(spacing: CanopySpacing.x5) {
                header

                liveCard

                Waveform()
                    .frame(height: 44)
                    .padding(.horizontal, CanopySpacing.x4)

                commandChip

                Spacer(minLength: 0)

                Dock(onNew: resetStream)
            }
            .padding(.top, CanopySpacing.x4)
            .padding(.bottom, CanopySpacing.x6)
        }
        .onReceive(streamTimer) { _ in
            if revealedWordCount < Self.sampleWords.count {
                revealedWordCount += 1
            }
        }
        .onReceive(caretTimer) { _ in
            caretVisible.toggle()
        }
    }

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: CanopyFont.sizeLg, weight: .semibold))
                    .foregroundStyle(CanopyColor.textMuted)
            }
            Spacer()
            Text("Live")
                .font(.system(size: CanopyFont.sizeSm, weight: .semibold))
                .foregroundStyle(CanopyColor.text)
            Spacer()
            // Balance the leading chevron so the title stays centered.
            Image(systemName: "chevron.down").opacity(0)
        }
        .padding(.horizontal, CanopySpacing.x4)
    }

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: CanopySpacing.x2) {
            HStack(spacing: CanopySpacing.x2) {
                Circle()
                    .fill(CanopyColor.danger)
                    .frame(width: 8, height: 8)
                Text("Recording")
                    .font(.system(size: CanopyFont.sizeXs, weight: .semibold))
                    .foregroundStyle(CanopyColor.textSubtle)
            }

            // Streaming text with a blinking caret appended inline.
            (
                Text(streamedText + " ")
                    .foregroundColor(CanopyColor.text)
                    + Text("|")
                    .foregroundColor(caretVisible ? CanopyColor.primary : .clear)
            )
            .font(.system(size: CanopyFont.sizeLg))
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CanopySpacing.x5)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .background(CanopyColor.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: CanopyRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CanopyRadius.xl, style: .continuous)
                .stroke(CanopyColor.border, lineWidth: 1)
        )
        .padding(.horizontal, CanopySpacing.x4)
    }

    private var commandChip: some View {
        HStack(spacing: CanopySpacing.x2) {
            Image(systemName: "arrow.uturn.backward")
            Text("Mira - removed last sentence")
        }
        .font(.system(size: CanopyFont.sizeSm))
        .foregroundStyle(CanopyColor.mutedForeground)
        .padding(.horizontal, CanopySpacing.x4)
        .padding(.vertical, CanopySpacing.x2)
        .background(CanopyColor.muted)
        .clipShape(Capsule())
    }

    private func resetStream() {
        revealedWordCount = 1
    }
}

/// A simple animated waveform row: vertical bars that breathe using the primary color.
private struct Waveform: View {
    @State private var animate = false
    private let bars = 28

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: CanopySpacing.x1) {
                ForEach(0..<bars, id: \.self) { index in
                    Capsule()
                        .fill(CanopyColor.primary)
                        .frame(height: barHeight(index: index, maxHeight: proxy.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(
                .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                value: animate
            )
        }
        .onAppear { animate = true }
    }

    // A stable pseudo-wave so bars vary in height; scaled when animating.
    private func barHeight(index: Int, maxHeight: CGFloat) -> CGFloat {
        let base = (sin(Double(index) * 0.7) + 1) / 2 // 0...1
        let factor = animate ? (0.35 + base * 0.65) : (0.2 + base * 0.3)
        return max(4, maxHeight * CGFloat(factor))
    }
}

/// The bottom dock: Pause | big circular Mira record button | New.
private struct Dock: View {
    let onNew: () -> Void

    var body: some View {
        HStack {
            dockButton(title: "Pause", system: "pause.fill") {}
            Spacer()
            recordButton
            Spacer()
            dockButton(title: "New", system: "plus", action: onNew)
        }
        .padding(.horizontal, CanopySpacing.x8)
    }

    private var recordButton: some View {
        Button {} label: {
            ZStack {
                Circle()
                    .fill(CanopyColor.primary)
                    .frame(width: 76, height: 76)
                    .shadow(color: CanopyColor.overlay.opacity(0.3), radius: 14, y: 6)
                Image(systemName: "waveform")
                    .font(.system(size: CanopyFont.sizeX2xl, weight: .semibold))
                    .foregroundStyle(CanopyColor.primaryForeground)
            }
        }
        .accessibilityLabel("Mira record")
    }

    private func dockButton(
        title: String,
        system: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: CanopySpacing.x1) {
                Image(systemName: system)
                    .font(.system(size: CanopyFont.sizeXl))
                Text(title)
                    .font(.system(size: CanopyFont.sizeXs))
            }
            .foregroundStyle(CanopyColor.textMuted)
            .frame(width: 64)
        }
    }
}

#Preview {
    DictationView()
}
