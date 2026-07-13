import XCTest
@testable import ThoughtStream

/// `UserDefaultsSettingsStore`: persistence of the control phrase and spelling overrides across
/// instances, and control-phrase validation (empty / whitespace / too-long fall back to "Mira").
final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "SettingsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Control phrase persistence

    func testControlPhrasePersistsAcrossInstances() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        store.controlPhrase = "Nova"

        let reopened = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.controlPhrase, "Nova")
    }

    func testControlPhraseIsTrimmedOnRead() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        store.controlPhrase = "  Nova  "
        XCTAssertEqual(store.controlPhrase, "Nova")
    }

    // MARK: - Control phrase validation

    func testEmptyControlPhraseFallsBackToMira() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        store.controlPhrase = ""
        XCTAssertEqual(store.controlPhrase, "Mira")
    }

    func testWhitespaceControlPhraseFallsBackToMira() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        store.controlPhrase = "   \n  "
        XCTAssertEqual(store.controlPhrase, "Mira")
    }

    func testDefaultControlPhraseIsMira() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(store.controlPhrase, "Mira")
    }

    func testTooLongControlPhraseFallsBackToMira() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        store.controlPhrase = String(repeating: "a", count: 100)
        XCTAssertEqual(store.controlPhrase, "Mira")
    }

    func testValidatedControlPhraseIsPure() {
        XCTAssertEqual(UserDefaultsSettingsStore.validatedControlPhrase("Nova"), "Nova")
        XCTAssertEqual(UserDefaultsSettingsStore.validatedControlPhrase("  "), "Mira")
        XCTAssertEqual(
            UserDefaultsSettingsStore.validatedControlPhrase(String(repeating: "x", count: 40)),
            "Mira"
        )
    }

    // MARK: - Spelling overrides persistence

    func testOverridesPersistAcrossInstances() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        store.spellingOverrides = [
            SpellingOverride(from: "Shay", to: "Shea"),
            SpellingOverride(from: "sea", to: "see"),
        ]

        let reopened = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.spellingOverrides.count, 2)
        XCTAssertEqual(reopened.spellingOverrides[0].from, "Shay")
        XCTAssertEqual(reopened.spellingOverrides[0].to, "Shea")
        XCTAssertEqual(reopened.spellingOverrides[1].from, "sea")
    }

    func testOverridesDefaultToEmpty() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertTrue(store.spellingOverrides.isEmpty)
    }

    func testOverridesPreserveOrder() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let list = (0..<5).map { SpellingOverride(from: "from\($0)", to: "to\($0)") }
        store.spellingOverrides = list

        let reopened = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.spellingOverrides.map(\.from), list.map(\.from))
    }
}
