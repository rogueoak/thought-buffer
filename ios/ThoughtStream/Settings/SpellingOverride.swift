import Foundation

/// A user-taught spelling fix: a spoken word the recognizer gets wrong (`from`) and the text to
/// write instead (`to`). Applied whole-word and case-insensitively to dictated text before commit.
///
/// See `SpellingOverrideProcessor` for the matching rules and `SettingsStoring` for persistence.
struct SpellingOverride: Codable, Equatable, Identifiable {
    /// A stable id so SwiftUI lists can track rows across edits. Not persisted-meaningful; just
    /// identity for the UI.
    let id: UUID
    /// The word as recognized (the mistake). Matched case-insensitively, whole-word.
    var from: String
    /// The word to write instead (the correction). Written as the user typed it.
    var to: String

    init(id: UUID = UUID(), from: String, to: String) {
        self.id = id
        self.from = from
        self.to = to
    }
}
