import AVFoundation

/// A candidate text-to-speech voice, reduced to the fields the selection cares about so the choice is
/// pure and unit-testable without the real `AVSpeechSynthesisVoice` catalog (spec 0014).
struct VoiceOption: Equatable {
    let identifier: String
    let language: String
    let quality: AVSpeechSynthesisVoiceQuality

    init(identifier: String, language: String, quality: AVSpeechSynthesisVoiceQuality) {
        self.identifier = identifier
        self.language = language
        self.quality = quality
    }
}

/// Picks the best installed text-to-speech voice for the user's language, so spoken text uses a
/// natural (premium / enhanced) voice instead of the robotic system default when one is installed
/// (spec 0014). Pure so the preference order is testable; the real catalog is injected by the caller.
enum VoiceSelector {
    /// The identifier of the best voice in `voices` for `languageCode` (e.g. "en-US"), or nil when no
    /// voice shares the language (the caller then keeps the system default). Preference:
    /// exact-language match over a same-prefix different-region one; within the chosen pool, highest
    /// quality (premium > enhanced > default); ties broken by identifier for a stable, deterministic
    /// result.
    static func bestVoiceIdentifier(from voices: [VoiceOption], languageCode: String) -> String? {
        let prefix = languagePrefix(of: languageCode)
        let exact = voices.filter { $0.language == languageCode }
        let sameLanguage = voices.filter { languagePrefix(of: $0.language) == prefix }
        let pool = exact.isEmpty ? sameLanguage : exact
        guard !pool.isEmpty else { return nil }

        return pool.max { lhs, rhs in
            let lq = rank(lhs.quality), rq = rank(rhs.quality)
            if lq != rq { return lq < rq }
            // Same quality: prefer the identifier that sorts LATER so `max` yields the smallest one,
            // giving a stable pick independent of catalog order.
            return lhs.identifier > rhs.identifier
        }?.identifier
    }

    /// The two-letter language subtag ("en" from "en-US"), lowercased, for same-language matching.
    private static func languagePrefix(of languageCode: String) -> String {
        let base = languageCode.split(separator: "-").first.map(String.init) ?? languageCode
        return base.lowercased()
    }

    /// Higher is better: premium > enhanced > default. Unknown future cases rank as default.
    private static func rank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 3
        case .enhanced: return 2
        case .default: return 1
        @unknown default: return 1
        }
    }
}
