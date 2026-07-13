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

    /// The length cap is exercised at the on/off boundary (max accepted, max+1 rejected), where an
    /// off-by-one would live.
    func testControlPhraseLengthBoundary() {
        let atMax = String(repeating: "a", count: ControlPhrase.maxLength)
        let overMax = String(repeating: "a", count: ControlPhrase.maxLength + 1)
        XCTAssertEqual(ControlPhrase.validated(atMax), atMax)
        XCTAssertEqual(ControlPhrase.validated(overMax), "Mira")
    }

    /// The parser matches a single leading token, so a multi-word or punctuated phrase must
    /// collapse to the first alphanumeric token rather than being stored verbatim (which would
    /// silently disable all commands).
    func testControlPhraseCollapsesToFirstToken() {
        XCTAssertEqual(ControlPhrase.validated("Hey Nova"), "Hey")
        XCTAssertEqual(ControlPhrase.validated("Mira!"), "Mira")
        XCTAssertEqual(ControlPhrase.validated("  Nova, please "), "Nova")
        XCTAssertEqual(ControlPhrase.validated("Nova"), "Nova")
    }

    func testValidatedControlPhraseIsPure() {
        XCTAssertEqual(ControlPhrase.validated("Nova"), "Nova")
        XCTAssertEqual(ControlPhrase.validated("  "), "Mira")
        // The over-length fallback is covered by `testControlPhraseLengthBoundary`.
    }

    /// A phrase with no alphanumeric characters at all (only punctuation) has no first token, so it
    /// must fall back to the default rather than storing an unmatchable control word.
    func testAllNonAlphanumericControlPhraseFallsBackToMira() {
        XCTAssertEqual(ControlPhrase.validated("!!!"), "Mira")
        XCTAssertEqual(ControlPhrase.validated("--- ... ---"), "Mira")
        let store = UserDefaultsSettingsStore(defaults: defaults)
        store.controlPhrase = "!!!"
        XCTAssertEqual(store.controlPhrase, "Mira")
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

    // MARK: - Spelling overrides bounds

    func testOverrideCountIsCappedOnWrite() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let count = UserDefaultsSettingsStore.maxOverrideCount + 50
        store.spellingOverrides = (0..<count).map { SpellingOverride(from: "f\($0)", to: "t\($0)") }
        XCTAssertEqual(store.spellingOverrides.count, UserDefaultsSettingsStore.maxOverrideCount)
    }

    func testOverrideFieldLengthIsCappedOnWrite() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let long = String(repeating: "x", count: 500)
        store.spellingOverrides = [SpellingOverride(from: long, to: long)]
        let read = store.spellingOverrides[0]
        XCTAssertEqual(read.from.count, UserDefaultsSettingsStore.maxOverrideFieldLength)
        XCTAssertEqual(read.to.count, UserDefaultsSettingsStore.maxOverrideFieldLength)
    }

    /// The count cap is exercised exactly at the boundary: with `maxOverrideCount + 1` rows written,
    /// the last accepted row (index max-1) is kept and the one over the cap is dropped. This pins
    /// the off-by-one that `+50` would not catch.
    func testOverrideCountBoundaryKeepsLastAcceptedAndDropsOverflow() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let cap = UserDefaultsSettingsStore.maxOverrideCount
        let list = (0..<(cap + 1)).map { SpellingOverride(from: "f\($0)", to: "t\($0)") }
        store.spellingOverrides = list

        let read = store.spellingOverrides
        XCTAssertEqual(read.count, cap)
        // The last accepted item is kept...
        XCTAssertEqual(read.last?.from, "f\(cap - 1)")
        // ...and the one over the cap is dropped.
        XCTAssertFalse(read.contains { $0.from == "f\(cap)" })
    }

    // MARK: - Lock screen title (spec 0008)

    func testLockScreenTitleDefaultsToNoteTitle() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(store.lockScreenTitle, .noteTitle)
    }

    func testLockScreenTitlePersistsAcrossInstances() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        store.lockScreenTitle = .generic

        let reopened = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.lockScreenTitle, .generic)
    }

    func testUnknownLockScreenTitleTagFallsBackToNoteTitle() {
        // A value written by a newer build (or a corrupt default) must decode to the safe default.
        defaults.set("someFutureMode", forKey: "settings.lockScreenTitle")
        let store = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(store.lockScreenTitle, .noteTitle)
    }

    // MARK: - Corrupt / missing persisted data

    func testCorruptOverridesJSONFallsBackToEmpty() {
        // Garbage bytes under the overrides key must decode to [] rather than crashing the getter.
        defaults.set(Data([0xFF, 0x00, 0x01, 0x02, 0xAB]), forKey: "settings.spellingOverrides")
        let store = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(store.spellingOverrides, [])
    }

    func testTruncatedOverridesJSONFallsBackToEmpty() {
        // A valid JSON prefix that is cut off mid-structure must also fall back to [].
        let truncated = Data("[{\"id\":\"".utf8)
        defaults.set(truncated, forKey: "settings.spellingOverrides")
        let store = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(store.spellingOverrides, [])
    }

    func testMissingOverridesKeyReturnsEmpty() {
        // No data ever written under the key: the getter returns [] (no crash, no default rows).
        let store = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(store.spellingOverrides, [])
    }
}
