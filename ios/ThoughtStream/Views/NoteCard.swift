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
                // The clock/time-since-created and timer/duration pairs are shared with the note detail
                // header via `NoteMetaStats` (feedback 0013 tightens both to `x1`; feedback 0015 gives
                // the detail duration the same timer glyph) so the card and the detail page can't drift.
                NoteMetaStats(note: note)
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
