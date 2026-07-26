import SwiftUI

/// The thought metadata line shared by the list card (`ThoughtCard`) and the thought detail header
/// (`ThoughtDetailView`): a clock glyph with the relative "time since created", then a timer/word glyph
/// with the recording duration (feedback 0010) or word count. Both pairs pin their glyph tight to its
/// text with the SAME `CanopySpacing.x1` token (feedback 0013), and the duration/word stat uses the
/// same `timer` / `text.alignleft` glyph in both places (feedback 0015) - factoring it here is what
/// keeps the card and the detail page from drifting apart.
///
/// The relative time is wrapped in a `TimelineView` so it re-evaluates every minute against a live
/// reference and never freezes at render (feedback 0011).
struct ThoughtMetaStats: View {
    let thought: Thought

    var body: some View {
        HStack(spacing: CanopySpacing.x3) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: CanopySpacing.x1) {
                    Image(systemName: "clock")
                    Text(RelativeTime.label(for: thought.createdAt, relativeTo: context.date))
                }
            }
            HStack(spacing: CanopySpacing.x1) {
                Image(systemName: thought.hasAudio ? "timer" : "text.alignleft")
                Text(thought.metaStatLabel)
            }
        }
    }
}
