import SwiftUI

/// A single folder row in the Thoughts list (spec 0010), styled to match `NoteCard`: the same
/// surface, border, radius, and padding, with a folder glyph, the folder name, an item count, and a
/// trailing chevron (the row navigates into the folder, so a chevron is the right affordance here).
///
/// The item count is the number of direct children (notes + subfolders) at this folder, passed in by
/// the view that already has the projected list for the folder's path - the row stays a pure render.
struct FolderRow: View {
    let name: String
    /// Direct child count (immediate notes + immediate subfolders), for the "3 items" subtitle.
    let itemCount: Int

    private var itemCountLabel: String {
        "\(itemCount) " + (itemCount == 1 ? "item" : "items")
    }

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
                Text(itemCountLabel)
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
        .background(CanopyColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: CanopyRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CanopyRadius.lg, style: .continuous)
                .stroke(CanopyColor.border, lineWidth: 1)
        )
    }
}
