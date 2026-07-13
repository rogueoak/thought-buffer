import SwiftUI

/// Read-only detail for a single note: its paragraphs and timestamp, themed. When the note carries
/// a recording (spec 0007), a simple Play / Stop control plays it back in full.
struct NoteDetailView: View {
    let note: Note
    @StateObject private var playback: NotePlaybackModel

    /// Build the detail view. Prefers the ONE shared `NotePlaybackController` (so the phone and
    /// CarPlay drive the same media center and never race); when none is supplied - a preview, a
    /// screenshot build, or a bare call site - it falls back to a private controller over the given
    /// `resolver`, which resolves the recording lazily (off the main actor, at play time) so
    /// navigation never blocks on the coordinated presence check. When the note claims no audio, no
    /// play affordance shows.
    init(
        note: Note,
        resolver: AudioURLResolving,
        player: AudioNotePlayer? = nil,
        controller: NotePlaybackController? = nil
    ) {
        self.note = note
        // The full note is passed through so the shared playback controller titles the system Now
        // Playing item (lock screen / Control Center) and reads the recording duration.
        let controller = controller ?? NotePlaybackController(resolver: resolver, player: player)
        _playback = StateObject(wrappedValue: NotePlaybackModel(note: note, controller: controller))
    }

    var body: some View {
        ZStack {
            CanopyColor.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: CanopySpacing.x4) {
                    HStack(spacing: CanopySpacing.x2) {
                        Image(systemName: "clock")
                        Text(RelativeTime.label(for: note.createdAt))
                        Text("-")
                        Text("\(note.paragraphCount) paragraphs")
                    }
                    .font(.system(size: CanopyFont.sizeXs))
                    .foregroundStyle(CanopyColor.textSubtle)

                    if playback.canPlay {
                        playButton
                    }

                    ForEach(Array(note.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.system(size: CanopyFont.sizeBase))
                            .foregroundStyle(CanopyColor.text)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(CanopySpacing.x5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CanopyColor.surface)
                .clipShape(RoundedRectangle(cornerRadius: CanopyRadius.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CanopyRadius.lg, style: .continuous)
                        .stroke(CanopyColor.border, lineWidth: 1)
                )
                .padding(CanopySpacing.x4)
            }
        }
        .navigationTitle(note.title)
        .navigationBarTitleDisplayMode(.inline)
        // Stop playback if the user navigates away mid-play, so audio never keeps running off-screen.
        .onDisappear { playback.stop() }
    }

    /// The simple play / stop control for the note's recording. Play / stop only - no scrubbing or
    /// rate controls (spec 0007 keeps detail playback minimal).
    private var playButton: some View {
        Button {
            playback.toggle()
        } label: {
            HStack(spacing: CanopySpacing.x2) {
                Image(systemName: playback.isPlaying ? "stop.fill" : "play.fill")
                Text(playback.isPlaying ? "Stop" : "Play recording")
                    .font(.system(size: CanopyFont.sizeSm, weight: .semibold))
            }
            .foregroundStyle(CanopyColor.primaryForeground)
            .padding(.horizontal, CanopySpacing.x4)
            .padding(.vertical, CanopySpacing.x2)
            .background(CanopyColor.primary)
            .clipShape(Capsule())
        }
        .accessibilityLabel(playback.isPlaying ? "Stop recording" : "Play recording")
    }
}

#Preview {
    NavigationStack {
        NoteDetailView(note: MockNotes.all[0], resolver: StoreAudioURLResolver(store: NoteStore()))
    }
}
