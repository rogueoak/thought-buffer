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
            .split(preText: "", command: .command(.removeLastSentence))
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

    /// Spec 0018: the factory builds the parser from the FULL trigger set - the primary control word
    /// PLUS the aliases - read at call time, so an alias mishearing fires the command and an aliases
    /// edit takes effect on the next session.
    func testMakeTextProcessorBuildsParserFromFullAliasSet() {
        let store = MutableSettingsStore()
        store.controlPhrase = "Mira"
        let deps = AppDependencies(settingsStore: store)

        // Add an alias after the root exists; a processor built now must fire on it.
        store.controlPhraseAliases = ["mirror"]
        let processor = deps.makeTextProcessor()

        // The alias fires the command and is NOT written into the thought...
        XCTAssertEqual(
            processor.process("mirror new thought"),
            .split(preText: "", command: .command(.newThought))
        )
        // ...the primary word still fires...
        XCTAssertEqual(
            processor.process("Mira new thought"),
            .split(preText: "", command: .command(.newThought))
        )
        // ...and a word that is neither is ordinary text.
        XCTAssertEqual(processor.process("meera new thought"), .text("meera new thought"))
    }

    /// Spec 0016: the filler stage is present in the built processor only when `refineTranscript` is
    /// on, read at build time so a Settings toggle takes effect on the next session. When off, text
    /// commits verbatim; when on, standalone fillers are stripped.
    func testFillerStagePresentOnlyWhenRefineOn() {
        let store = MutableSettingsStore()
        let deps = AppDependencies(settingsStore: store)

        // Off: text commits verbatim.
        store.refineTranscript = false
        XCTAssertEqual(
            deps.makeTextProcessor().process("um the plan"),
            .text("um the plan")
        )

        // On: the filler stage strips the standalone filler and re-capitalizes.
        store.refineTranscript = true
        XCTAssertEqual(
            deps.makeTextProcessor().process("um the plan"),
            .text("The plan")
        )
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
    private var rawAliases: [String] = []
    var controlPhraseAliases: [String] {
        get { ControlPhrase.validatedAliases(rawAliases, primaryWord: controlPhrase) }
        set { rawAliases = newValue }
    }
    var spellingOverrides: [SpellingOverride] = []
    var audioRetention: AudioRetention = .keep
    var lockScreenTitle: LockScreenTitle = .noteTitle
    var thoughtSortOrder: ThoughtSortOrder = .newest
    var refineTranscript = true
}
