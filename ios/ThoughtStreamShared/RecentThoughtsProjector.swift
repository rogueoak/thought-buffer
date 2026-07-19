import Foundation

/// Builds the phone -> watch recent-thoughts projection from the thoughts the store already loads
/// (spec 0023). Pure and testable: it takes a `[Thought]` and returns a capped `[RecentThoughtProjection]`
/// (title + short preview + duration + id), so the watch renders a glanceable list without the full
/// thought model ever crossing the connectivity link. Runs on the phone; kept out of the session object
/// so the mapping (preview trimming, cap, newest-first ordering) is provable without a real watch.
enum RecentThoughtsProjector {
    /// The most thoughts the watch list shows. Bounded so a large library does not blow the
    /// applicationContext size limit (a few hundred bytes per row) or the wrist's tiny screen.
    static let defaultLimit = 25

    /// The longest preview kept for a row, so a long first paragraph does not bloat the payload.
    static let previewCap = 80

    /// Project the newest `limit` thoughts. Assumes `thoughts` is already newest-first (the store's
    /// `loadAll` returns them so), but does not depend on it beyond taking a prefix - the phone side
    /// passes the store's order through. Each row carries the derived title, a trimmed single-line
    /// preview, the recording duration (0 when text-only), and whether it has audio.
    static func project(
        _ thoughts: [Thought],
        limit: Int = RecentThoughtsProjector.defaultLimit
    ) -> [RecentThoughtProjection] {
        thoughts.prefix(max(0, limit)).map { thought in
            RecentThoughtProjection(
                id: thought.id,
                title: thought.title,
                preview: preview(for: thought),
                duration: thought.recordingDuration,
                hasAudio: thought.hasAudio
            )
        }
    }

    /// A short single-line preview from the first paragraph: newlines flattened to spaces, collapsed
    /// whitespace, trimmed, and capped with an ellipsis so a row never wraps awkwardly on the wrist.
    static func preview(for thought: Thought) -> String {
        let firstParagraph = thought.paragraphs.first ?? ""
        let flattened = firstParagraph
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        if flattened.count > previewCap {
            return String(flattened.prefix(previewCap)).trimmingCharacters(in: .whitespaces) + "..."
        }
        return flattened
    }
}
