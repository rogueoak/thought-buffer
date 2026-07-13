import XCTest
@testable import ThoughtStream

/// `AppDependencies.makeTextProcessor`: the default factory reads current settings at CALL time,
/// not at composition-root init time. This pins the session-switch contract - an edit in Settings
/// must take effect on the NEXT session, which only holds if the factory re-reads the store each
/// call rather than capturing values when the root is built.
@MainActor
final class AppDependenciesFactoryTests: XCTestCase {

    func testMakeTextProcessorReadsControlPhraseAtCallTime() {
        let store = MutableSettingsStore()
        store.controlPhrase = "Mira"

        // Build the composition root (and thus its default factory) while the phrase is "Mira".
        let deps = AppDependencies(settingsStore: store)

        // Change the control phrase AFTER the root - and its factory closure - already exist.
        store.controlPhrase = "Nova"

        // A processor built now must use the NEW word, proving the factory re-read the store rather
        // than capturing "Mira" at init.
        let processor = deps.makeTextProcessor()

        // The new word fires the command...
        XCTAssertEqual(
            processor.process("Nova remove the last sentence"),
            .command(.removeLastSentence)
        )
        // ...and the old word does not (it commits as plain text).
        XCTAssertEqual(
            processor.process("Mira remove the last sentence"),
            .text("Mira remove the last sentence")
        )
    }

    func testMakeTextProcessorReadsOverridesAtCallTime() {
        let store = MutableSettingsStore()
        let deps = AppDependencies(settingsStore: store)

        // Add an override after the root exists; a processor built now must apply it.
        store.spellingOverrides = [SpellingOverride(from: "Shay", to: "Shea")]
        let processor = deps.makeTextProcessor()
        XCTAssertEqual(processor.process("Call Shay today"), .text("Call Shea today"))
    }
}

/// An in-memory `SettingsStoring` for tests that need to mutate settings after the composition root
/// is built, without touching `UserDefaults`. Applies the same `ControlPhrase` validation on read
/// as the production store, so the contract under test matches production.
private final class MutableSettingsStore: SettingsStoring {
    private var rawControlPhrase = ""
    var controlPhrase: String {
        get { ControlPhrase.validated(rawControlPhrase) }
        set { rawControlPhrase = newValue }
    }
    var spellingOverrides: [SpellingOverride] = []
}
