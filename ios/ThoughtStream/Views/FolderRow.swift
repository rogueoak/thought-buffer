import SwiftUI

/// A single folder row in the Thoughts list (spec 0010), styled to match `ThoughtCard`: the same
/// padding, with a folder glyph, the folder name, a descendant-thought count, and a trailing chevron
/// (the row navigates into the folder, so a chevron is the right affordance here).
///
/// Feedback 0025 (unified list): the surface / border / rounded-corner chrome moved off this row onto the
/// whole list container (Notes-app-style grouped list), so only the row CONTENT lives here now.
///
/// The count label is a flattened thought count (e.g. "3 thoughts"), computed and pluralized in
/// `TopLevelFolders` by the view that already holds the thoughts - the row stays a pure render.
struct FolderRow: View {
    let name: String
    /// A pluralized descendant-thought count label (e.g. "No thoughts", "1 thought", "3 thoughts").
    let countLabel: String

    var body: some View {
        HStack(spacing: CanopySpacing.x3) {
            Image(systemName: "folder.fill")
                .font(.system(size: CanopyFont.sizeLg, weight: .semibold))
                .foregroundStyle(CanopyColor.primary)

            VStack(alignment: .leading, spacing: CanopySpacing.x1) {
                Text(name)
                    .font(.system(size: CanopyFont.sizeLg, weight: .semibold))
                    .foregroundStyle(CanopyColor.text)
                    .lineLimit(1)
                Text(countLabel)
                    .font(.system(size: CanopyFont.sizeXs))
                    .foregroundStyle(CanopyColor.textSubtle)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: CanopyFont.sizeSm, weight: .semibold))
                .foregroundStyle(CanopyColor.textSubtle)
        }
        .padding(CanopySpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
