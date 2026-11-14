import Foundation

/// Splits long utterances into at most two clauses at the first eligible punctuation mark, so the
/// translation pipeline can start earlier on the first half (QS-5, REQ-CS-01…04).
nonisolated enum ClauseSplitter {
    static let minWords = 12
    static let minWordsBefore = 5
    static let minWordsAfter = 4

    private static let marks: Set<Character> = [",", ";", ":"]

    /// Returns 1 or 2 parts. The first part keeps its clause mark; parts are whitespace-normalised.
    static func split(_ text: String) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= minWords else { return [text] }
        for (index, word) in words.enumerated() {
            guard let last = word.last, marks.contains(last) else { continue }
            let wordsBefore = index + 1
            let wordsAfter = words.count - wordsBefore
            if wordsBefore < minWordsBefore { continue }
            guard wordsAfter >= minWordsAfter else { return [text] }
            let head = words[words.startIndex...words.index(words.startIndex, offsetBy: index)]
            let tail = words[words.index(words.startIndex, offsetBy: index + 1)...]
            return [head.joined(separator: " "), tail.joined(separator: " ")]
        }
        return [text]
    }
}
