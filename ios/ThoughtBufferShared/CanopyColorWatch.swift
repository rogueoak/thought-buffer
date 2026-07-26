import SwiftUI

/// The watchOS implementation of the Canopy `Color(light:dark:)` / `Color(rgb:)` builders (spec 0023).
///
/// These live HERE, hand-owned, rather than inside the vendored, generated `Tokens.swift` ("Do not edit")
/// - a fix inside that file would be silently dropped on a Canopy re-sync and break the watch build. The
/// generated `CanopyColor` enum still holds the token VALUES (`Color(light:dark:)` calls); this file only
/// supplies the platform GLUE the watch needs, because `UIColor(dynamicProvider:)` and trait
/// `userInterfaceStyle` are `API_UNAVAILABLE(watchos)`. The generated file's own copy of this extension is
/// excluded on watchOS by a two-line `#if !os(watchOS)` wrapper (the one marked hand-edit there), so there
/// is exactly one definition per platform and no redeclaration clash.
///
/// The watch renders on a dark background, so a semantic color resolves to its DARK value.
#if os(watchOS)
public extension Color {
    /// A color that resolves to its dark value on the watch (the watch UI is dark). watchOS has no
    /// dynamic-provider `UIColor`, so this is a static resolution rather than a live trait-reactive one.
    init(light: UInt, dark: UInt) {
        self = Color(rgb: dark)
    }

    init(rgb: UInt) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}
#endif
