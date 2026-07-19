import SwiftUI

/// A single note card in the Stream list: title, two-line snippet, timestamp, the note's stat
/// (recording duration when it has audio, else word count - feedback 0010), a play affordance when
/// the note has audio, and a small primary accent dot.
struct NoteCard: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: CanopySpacing.x2) {
            HStack(alignment: .firstTextBaseline, spacing: CanopySpacing.x2) {
                Circle()
                    .fill(CanopyColor.primary)
                    .frame(width: 8, height: 8)
                    .padding(.top, CanopySpacing.x1)
                Text(note.title)
                    .font(.system(size: CanopyFont.sizeLg, weight: .semibold))
                    .foregroundStyle(CanopyColor.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Text(note.snippet)
                .font(.system(size: CanopyFont.sizeSm))
                .foregroundStyle(CanopyColor.textMuted)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack(spacing: CanopySpacing.x3) {
                // Relative time must carry a time dependency or it FREEZES at render (feedback 0011):
                // SwiftUI has no wall-clock trigger, so a "3 min ago" written just after save stayed
                // "3 min ago" (which read as the note's own length). A `TimelineView` re-evaluates the
                // label every minute against a live `context.date`, so the list never goes stale. The
                // glyph is paired tight (`x1`) with its text instead of the default Label gap.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    HStack(spacing: CanopySpacing.x1) {
                        Image(systemName: "clock")
                        Text(RelativeTime.label(for: note.createdAt, relativeTo: context.date))
                    }
                }
                // Duration for a recorded note (timer glyph), word count otherwise (feedback 0010).
                // Paired with the SAME tight `x1` gap as the clock pair above (feedback 0013) instead
                // of the looser default `Label` spacing, so the two metadata pairs stay in sync.
                HStack(spacing: CanopySpacing.x1) {
                    Image(systemName: note.hasAudio ? "timer" : "text.alignleft")
                    Text(note.metaStatLabel)
                }
                // A small play affordance so a note with a recording is discoverable at a glance
                // (feedback 0005); tapping the card still navigates to the detail view to play.
                if note.hasAudio {
                    Label("Recording", systemImage: "play.circle")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(CanopyColor.primary)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: CanopyFont.sizeXs))
            .foregroundStyle(CanopyColor.textSubtle)
        }
        .padding(CanopySpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CanopyColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: CanopyRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CanopyRadius.lg, style: .continuous)
                .stroke(CanopyColor.border, lineWidth: 1)
        )
    }
}
