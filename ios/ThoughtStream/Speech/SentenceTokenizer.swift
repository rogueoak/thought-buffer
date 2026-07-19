import Foundation
import NaturalLanguage

/// Splits text into sentences, used by the "remove the last sentence" command.
///
/// Backed by `NLTokenizer` with the `.sentence` unit, which handles terminal punctuation and
/// common abbreviations better than a naive split on periods.
enum SentenceTokenizer {
    /// The sentences in `text`, trimmed, with empties dropped. A string with no terminal
    /// punctuation returns as a single sentence.
    static func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { result.append(sentence) }
            return true
        }
        return result
    }

    /// The paragraph with its last sentence removed, or nil if nothing remains (the caller then
    /// drops the whole paragraph so the thought stays coherent).
    static func removingLastSentence(from paragraph: String) -> String? {
        var sentences = sentences(in: paragraph)
        guard !sentences.isEmpty else { return nil }
        sentences.removeLast()
        guard !sentences.isEmpty else { return nil }
        return sentences.joined(separator: " ")
    }
}
