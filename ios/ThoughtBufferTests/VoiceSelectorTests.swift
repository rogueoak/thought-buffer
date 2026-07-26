import XCTest
import AVFoundation
@testable import ThoughtBuffer

/// The best-voice selection (spec 0014) drives whether "read that back" and text-only playback sound
/// natural or robotic. These pin the preference order (premium > enhanced > default), the
/// exact-language-over-region rule, the no-match fallback, and determinism - the pure part; the real
/// spoken quality is device-verified.
final class VoiceSelectorTests: XCTestCase {
    private func voice(_ id: String, _ lang: String, _ q: AVSpeechSynthesisVoiceQuality) -> VoiceOption {
        VoiceOption(identifier: id, language: lang, quality: q)
    }

    func testPrefersPremiumOverEnhancedAndDefault() {
        let voices = [
            voice("v.default", "en-US", .default),
            voice("v.premium", "en-US", .premium),
            voice("v.enhanced", "en-US", .enhanced),
        ]
        XCTAssertEqual(VoiceSelector.bestVoiceIdentifier(from: voices, languageCode: "en-US"), "v.premium")
    }

    func testPrefersEnhancedWhenNoPremium() {
        let voices = [
            voice("v.default", "en-US", .default),
            voice("v.enhanced", "en-US", .enhanced),
        ]
        XCTAssertEqual(VoiceSelector.bestVoiceIdentifier(from: voices, languageCode: "en-US"), "v.enhanced")
    }

    func testNilWhenNoSameLanguageVoice() {
        let voices = [
            voice("v.fr", "fr-FR", .premium),
            voice("v.de", "de-DE", .enhanced),
        ]
        XCTAssertNil(VoiceSelector.bestVoiceIdentifier(from: voices, languageCode: "en-US"))
    }

    func testPrefersExactLanguageOverSamePrefixDifferentRegion() {
        // A premium en-GB should NOT beat an exact en-US default: an exact-region match wins its pool.
        let voices = [
            voice("v.gb.premium", "en-GB", .premium),
            voice("v.us.default", "en-US", .default),
        ]
        XCTAssertEqual(VoiceSelector.bestVoiceIdentifier(from: voices, languageCode: "en-US"), "v.us.default")
    }

    func testFallsBackToSamePrefixWhenNoExactRegion() {
        // No en-US at all: a same-language (en) voice is used, best quality among them.
        let voices = [
            voice("v.gb.enhanced", "en-GB", .enhanced),
            voice("v.au.default", "en-AU", .default),
        ]
        XCTAssertEqual(VoiceSelector.bestVoiceIdentifier(from: voices, languageCode: "en-US"), "v.gb.enhanced")
    }

    func testExactRegionMatchIsCaseInsensitive() {
        // A case-skewed request ("en-us") must still treat the "en-US" voice as an exact-region match.
        let voices = [
            voice("v.gb.premium", "en-GB", .premium),
            voice("v.us.default", "en-US", .default),
        ]
        XCTAssertEqual(VoiceSelector.bestVoiceIdentifier(from: voices, languageCode: "en-us"), "v.us.default")
    }

    func testRegionlessLanguageCodeUsesPrefixPool() {
        // `currentLanguageCode()` can be region-less ("en"): with no exact match, pick the best same
        // language voice.
        let voices = [
            voice("v.us.default", "en-US", .default),
            voice("v.gb.premium", "en-GB", .premium),
        ]
        XCTAssertEqual(VoiceSelector.bestVoiceIdentifier(from: voices, languageCode: "en"), "v.gb.premium")
    }

    func testDeterministicTieBreakAcrossEqualQuality() {
        let a = [voice("v.b", "en-US", .premium), voice("v.a", "en-US", .premium)]
        let b = [voice("v.a", "en-US", .premium), voice("v.b", "en-US", .premium)]
        let pickA = VoiceSelector.bestVoiceIdentifier(from: a, languageCode: "en-US")
        let pickB = VoiceSelector.bestVoiceIdentifier(from: b, languageCode: "en-US")
        XCTAssertEqual(pickA, pickB, "equal-quality pick must not depend on catalog order")
        XCTAssertEqual(pickA, "v.a")
    }
}
