import Testing
@testable import TranslateCall

@Suite("WordErrorRate")
struct WordErrorRateTests {
    @Test func identicalIsZero() {
        #expect(WordErrorRate.compute(reference: "hola qué tal", hypothesis: "hola qué tal") == 0)
    }

    @Test func ignoresCaseAndPunctuation() {
        #expect(WordErrorRate.compute(reference: "Hola, ¿qué tal?", hypothesis: "hola que tal") == 0)
    }

    @Test func oneSubstitutionOfFour() {
        #expect(WordErrorRate.compute(reference: "can you hear me", hypothesis: "can you see me") == 0.25)
    }

    @Test func deletionAndInsertion() {
        // ref 3 words; hyp drops one and adds one → 2 edits / 3
        let wer = WordErrorRate.compute(reference: "добрий день друже", hypothesis: "добрий друже привіт")
        #expect(abs(wer - 2.0 / 3.0) < 1e-9)
    }

    @Test func emptyHypothesisIsOne() {
        #expect(WordErrorRate.compute(reference: "a b", hypothesis: "") == 1)
    }
}
