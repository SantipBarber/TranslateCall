import Foundation

/// Word error rate = (substitutions + deletions + insertions) / reference word count.
/// Case-, diacritic- and punctuation-insensitive so "qué" == "que".
enum WordErrorRate {
    static func compute(reference: String, hypothesis: String) -> Double {
        let ref = words(reference), hyp = words(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        var prev = Array(0...hyp.count)
        for i in 1...ref.count {
            var cur = [i] + Array(repeating: 0, count: hyp.count)
            for j in stride(from: 1, through: hyp.count, by: 1) {
                let cost = ref[i - 1] == hyp[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = cur
        }
        return Double(prev[hyp.count]) / Double(ref.count)
    }

    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
