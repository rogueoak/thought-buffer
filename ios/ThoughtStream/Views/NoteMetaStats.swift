import SwiftUI

/// The note metadata line shared by the list card (`NoteCard`) and the note detail header
/// (`NoteDetailView`): a clock glyph with the relative "time since created", then a timer/word glyph
/// with the recording duration (feedback 0010) or word count. Both pairs pin their glyph tight to its
/// text with the SAME `CanopySpacing.x1` token (feedback 0013), and the duration/word stat uses the
/// same `timer` / `text.alignleft` glyph in both places (feedback 0015) - factoring it here is what
/// keeps the card and the detail page from drifting apart.
///
/// The relative time is wrapped in a `TimelineView` so it re-evaluates every minute against a live
/// reference and never freezes at render (feedback 0011).
struct NoteMetaStats: View {
    let note: Note

    var body: some View {
        HStack(spacing: CanopySpacing.x3) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: CanopySpacing.x1) {
                    Image(systemName: "clock")
                    Text(RelativeTime.label(for: note.createdAt, relativeTo: context.date))
                }
            }
            HStack(spacing: CanopySpacing.x1) {
                Image(systemName: note.hasAudio ? "timer" : "text.alignleft")
                Text(note.metaStatLabel)
            }
        }
    }
}
