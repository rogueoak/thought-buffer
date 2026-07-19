import SwiftUI

/// The persistent bottom bar shared across the list, folder, and thought-detail screens (spec 0021): a
/// SEARCH FIELD filling most of the width on the left, and a small set of ICON-ONLY action buttons on
/// the right. It is factored so each screen passes in its own right-side actions via `trailing` rather
/// than forking the bar per screen - the list/folder pass a new-thought + record pair, the thought-detail
/// passes a resume icon (only when resuming applies).
///
/// The bar drops the text labels the old toolbar/record pill carried (to make room for the field), but
/// keeps ACCESSIBILITY labels on the now-unlabeled buttons - callers set those on the buttons they hand
/// in via `trailing`. The record/resume icon keeps its recording-state affordance without a text label.
struct BottomBar<Trailing: View>: View {
    /// The live search text. Two-way bound so the field drives the host's results and clearing it
    /// restores the normal view.
    @Binding var query: String
    /// Whether to show the search field at all. Hidden only in a truly empty store (nothing to search),
    /// per `FolderScreenState.showsSearchField`; the trailing actions still show so Record is reachable.
    let showsSearchField: Bool
    /// Called when the user submits the field (Search key). Nil on screens that filter live off `query`
    /// (the folder list); the thought-detail page passes one so submitting routes to the global results
    /// rather than popping on the first keystroke.
    let onSubmit: (() -> Void)?
    /// The screen's icon-only right-side actions (new-thought + record for lists, resume for thoughts), passed
    /// in so the bar is not forked per screen.
    @ViewBuilder let trailing: Trailing

    init(
        query: Binding<String>,
        showsSearchField: Bool = true,
        onSubmit: (() -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self._query = query
        self.showsSearchField = showsSearchField
        self.onSubmit = onSubmit
        self.trailing = trailing()
    }

    var body: some View {
        // The search field is its OWN bounded (rounded) field; the action buttons sit BESIDE it, visually
        // OUTSIDE that field's background (feedback 0020). Previously one shared capsule wrapped the field AND
        // the buttons, so the new-thought / record icons read as being INSIDE the search field. Now only the
        // field carries the surface + border pill, and the trailing icons stand on the bare bar next to it.
        HStack(spacing: CanopySpacing.x3) {
            if showsSearchField {
                searchField
            }
            trailing
        }
        .padding(.horizontal, CanopySpacing.x4)
    }

    /// The search field: a magnifier glyph, a text field filling the remaining width, and a clear
    /// button when there is text, all inside its OWN rounded pill (surface + border + shadow) so it reads as
    /// a bounded search field distinct from the action buttons beside it (feedback 0020). Uses `.search`
    /// submit semantics but never fights the dictation mic - the record/resume action is a distinct button in
    /// `trailing` (spec 0021 keyboard thought).
    private var searchField: some View {
        HStack(spacing: CanopySpacing.x2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: CanopyFont.sizeSm, weight: .semibold))
                .foregroundStyle(CanopyColor.textSubtle)
            TextField("Search thoughts", text: $query)
                .font(.system(size: CanopyFont.sizeSm))
                .foregroundStyle(CanopyColor.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { onSubmit?() }
                .accessibilityLabel("Search thoughts")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: CanopyFont.sizeSm))
                        .foregroundStyle(CanopyColor.textSubtle)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CanopySpacing.x4)
        .padding(.vertical, CanopySpacing.x2)
        .background(CanopyColor.surface)
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(CanopyColor.border, lineWidth: 1)
        )
        .shadow(color: CanopyColor.overlay.opacity(0.2), radius: 12, y: 6)
    }
}

/// A round, icon-only bottom-bar action button (spec 0021): a tappable glyph tinted in the primary
/// token, sized as a comfortable tap target, with the accessibility label the caller supplies (the
/// text label is dropped to make room for the search field). Used for the new-thought and resume actions.
struct BottomBarIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: CanopyFont.sizeLg, weight: .semibold))
                .foregroundStyle(CanopyColor.primary)
                .frame(width: CanopySpacing.x8, height: CanopySpacing.x8)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

/// The record/resume icon-only button for the bottom bar (spec 0021): a filled mic glyph on the primary
/// surface, keeping its prominent, always-active affordance WITHOUT a text label. The list/folder
/// screens use it as "Record" (start a fresh session) and the thought-detail as "Resume recording", set
/// via `accessibilityLabel`.
struct BottomBarRecordButton: View {
    var accessibilityLabel: String = "Record"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "mic.fill")
                .font(.system(size: CanopyFont.sizeBase, weight: .semibold))
                .foregroundStyle(CanopyColor.primaryForeground)
                .frame(width: CanopySpacing.x8, height: CanopySpacing.x8)
                .background(CanopyColor.primary)
                .clipShape(Circle())
                .shadow(color: CanopyColor.overlay.opacity(0.25), radius: 8, y: 4)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}
