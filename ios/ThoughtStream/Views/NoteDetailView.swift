import SwiftUI

/// Read-only detail for a single note: its paragraphs and timestamp, themed.
struct NoteDetailView: View {
    let note: Note

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
    }
}

#Preview {
    NavigationStack {
        NoteDetailView(note: MockNotes.all[0])
    }
}
