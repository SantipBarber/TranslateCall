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

    /// The translation of a later part, which continues a sentence: its first letter is lowercased
    /// when the source part starts lowercase, so the joined text reads "lentos, los estilos", not
    /// "lentos, Los estilos". Kept as is: a source starting uppercase (a name, "I"), a source whose
    /// second word is capitalised ("the West" → "Occidente"), and an all-caps first word (an acronym).
    static func continuing(_ translation: String, source: String) -> String {
        let sourceWords = source.split(whereSeparator: \.isWhitespace)
        guard let sourceFirst = sourceWords.first?.first, sourceFirst.isLowercase,
              !(sourceWords.dropFirst().first?.first?.isUppercase ?? false),
              let first = translation.first, first.isUppercase else { return translation }
        let firstWord = translation.prefix { !$0.isWhitespace }
        let isAcronym = firstWord.filter(\.isLetter).count > 1 && firstWord.allSatisfy { !$0.isLowercase }
        return isAcronym ? translation : first.lowercased() + translation.dropFirst()
    }
}
