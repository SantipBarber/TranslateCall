import Testing
import Foundation
@testable import TranslateCall

private let enLanguage = Locale.Language(identifier: "en")
private let esLanguage = Locale.Language(identifier: "es")

/// 13 words with a comma after the 6th: splits into two eligible clauses (REQ-CS-01…04).
private let thirteenWordsWithComma = "When we get to the station, we will call you from the taxi"

@Suite("SentenceTranslation (QS-5)", .serialized) @MainActor
struct SentenceTranslationTests {

    @Test("split off keeps the whole sentence as the single part")
    func wholeWhenSplitOff() async {
        let mock = MockTranslationService()
        let translation = SentenceTranslation(thirteenWordsWithComma, split: false) { text in
            try await mock.translate(text: text, from: enLanguage, to: esLanguage)
        }

        #expect(translation.parts == [thirteenWordsWithComma])
        #expect(translation.tasks.count == 1)
        #expect(translation.isSplit == false)
    }

    @Test("each part translates to TRANSLATED: <part> (QS-5, design §3)")
    func twoPartsTranslatedSeparately() async throws {
        let mock = MockTranslationService()
        let translation = SentenceTranslation(thirteenWordsWithComma, split: true) { text in
            try await mock.translate(text: text, from: enLanguage, to: esLanguage)
        }

        #expect(translation.isSplit == true)
        #expect(try await translation.tasks[0].value == "TRANSLATED: \(translation.parts[0])")
        #expect(try await translation.tasks[1].value == "TRANSLATED: \(translation.parts[1])")
    }

    @Test("a later part continues the sentence: lowercase start (ClauseSplitter.continuing)")
    func laterPartStartsLowercase() async throws {
        let translation = SentenceTranslation(thirteenWordsWithComma, split: true) { text in
            text.hasPrefix("When") ? "Cuando lleguemos a la estación," : "Te llamaremos desde el taxi"
        }

        #expect(try await translation.tasks[0].value == "Cuando lleguemos a la estación,")
        #expect(try await translation.tasks[1].value == "te llamaremos desde el taxi")
    }

    @Test("cancel() cancels every part still translating")
    func cancelCancelsEveryPart() async throws {
        let mock = MockTranslationService()
        let parts = ClauseSplitter.split(thirteenWordsWithComma)
        let translation = SentenceTranslation(thirteenWordsWithComma, split: true) { text in
            try await mock.translate(text: text, from: enLanguage, to: esLanguage)
        }
        mock.holdTexts = Set(parts)
        #expect(await waitUntil { mock.heldCount == 2 })

        translation.cancel()

        var caught: [Error] = []
        for task in translation.tasks {
            do { _ = try await task.value } catch { caught.append(error) }
        }
        #expect(caught.count == 2)
        #expect(caught.allSatisfy { $0 is CancellationError })
    }

    @Test("parts reach the bridge in order, as separate sentences (P-1)")
    func partsReachTheBridgeInOrder() async throws {
        let model = TranslationBridgeModel()
        let driver = TranslationSessionDriver(model: model)
        defer { driver.stop() }
        let translation = SentenceTranslation(thirteenWordsWithComma, split: true) { text in
            try await model.translate(text, from: enLanguage, to: esLanguage)
        }

        var values: [String] = []
        for task in translation.tasks { values.append(try await task.value) }

        #expect(driver.session.translated == translation.parts)
        #expect(values.count == translation.parts.count)
    }
}
