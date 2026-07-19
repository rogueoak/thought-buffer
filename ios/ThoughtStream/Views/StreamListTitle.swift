import SwiftUI
import UIKit

/// The screen title as the FIRST row of the scrollable list (spec 0026), so it scrolls away with the
/// content instead of sitting pinned below the toolbar. Rendered at the same Canopy H3 size + bold weight
/// the old fixed title used (`StreamListTitle`), inset to line up with the cards below it, and stripped of
/// list-row chrome so it reads as a plain header. Every top-level and folder list uses this one row, so the
/// title placement is single-sourced.
struct StreamListTitleRow: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: StreamListTitle.fontSize, weight: .bold))
            .foregroundStyle(CanopyColor.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(
                top: CanopySpacing.x3,
                leading: CanopySpacing.x4,
                bottom: CanopySpacing.x2,
                trailing: CanopySpacing.x4
            ))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The below-the-toolbar list title for the Thoughts / folder screens (spec 0021, sized down by feedback
/// 0020). The title stays a LARGE navigation title BELOW the toolbar buttons - only its type size changes.
///
/// NOTE (spec 0026): the redesigned top-level and folder screens now render the title as the first
/// SCROLLABLE row via `StreamListTitleRow` instead of this fixed navigation title, so `.streamListTitle`
/// is no longer applied there. It is retained for any screen that still wants a fixed large title.
///
/// Device feedback 0020: the system large title read one Canopy step too big (roughly an H2). This drops it
/// ONE step on the Canopy scale (`sizeX3xl`, the H3-equivalent) so the header is calmer while keeping the
/// same placement, weight, and behavior. The size choice is the pure, tested `StreamListTitle.fontSize` so
/// the "one step down" rule is verifiable without rendering.
enum StreamListTitle {
    /// The point size for the large list title: one Canopy step below the old system large title, i.e. the
    /// H3-equivalent `sizeX3xl`. Kept as a pure token read so a test can assert we stayed on the scale and
    /// did not hardcode a raw point size.
    static var fontSize: CGFloat { CanopyFont.sizeX3xl }

    /// The weight the large title keeps (bold, matching the system large title it replaces).
    static let fontWeight: UIFont.Weight = .bold
}

private extension View {
    /// Apply the Canopy-sized large title font to the navigation bar for this screen. SwiftUI has no
    /// modifier for the large-title font, so we set it on a `UINavigationBarAppearance` and assign it to the
    /// bar as the screen appears; the size is the tested `StreamListTitle.fontSize` (one step below the
    /// system large title, per feedback 0020). Scoped to appearance so it does not leak into other bars
    /// (Settings / Move-to-folder keep their inline titles).
    func canopyLargeTitleFont() -> some View {
        background(LargeTitleFontApplier())
    }
}

/// A zero-size host that installs the Canopy large-title font on its enclosing navigation bar (feedback
/// 0020). It walks up to the `UINavigationController` and overrides the large-title text attributes with
/// the `StreamListTitle` size + weight, so the below-the-toolbar title renders one Canopy step smaller
/// without touching placement or behavior.
private struct LargeTitleFontApplier: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        Applier()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    final class Applier: UIViewController {
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard let bar = navigationController?.navigationBar else { return }
            let font = UIFont.systemFont(ofSize: StreamListTitle.fontSize, weight: StreamListTitle.fontWeight)

            let appearance = bar.standardAppearance.copy()
            appearance.largeTitleTextAttributes[.font] = font
            bar.standardAppearance = appearance

            let scrollEdge = (bar.scrollEdgeAppearance ?? appearance).copy()
            scrollEdge.largeTitleTextAttributes[.font] = font
            bar.scrollEdgeAppearance = scrollEdge

            view.frame = .zero
            view.isUserInteractionEnabled = false
        }
    }
}

extension View {
    /// Present a Thoughts / folder screen's below-the-toolbar large title at the Canopy H3 size (feedback
    /// 0020). Bundles `.navigationTitle` + `.navigationBarTitleDisplayMode(.large)` with the smaller Canopy
    /// large-title font, so every folder-screen call site sets the title the SAME way and the size lives in
    /// one place.
    func streamListTitle(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .canopyLargeTitleFont()
    }
}
