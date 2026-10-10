@_exported import Testing
import Foundation
@testable import TranslateCall

// MARK: - TranslationError

@MainActor
struct TranslationErrorTests {

    @Test func timedOutHasDescription() {
        #expect(TranslationError.timedOut.errorDescription == "Translation took too long.")
    }

    @Test func sessionErrorWrapsInnerDescription() {
        struct Dummy: Error, LocalizedError {
            var errorDescription: String? { "dummy error" }
        }
        let error = TranslationError.sessionError(Dummy())
        #expect(error.errorDescription?.contains("dummy error") == true)
    }

    @Test func unsupportedPairIncludesLanguageIdentifiers() {
        let src = Locale.Language(identifier: "en")
        let tgt = Locale.Language(identifier: "xx")
        let error = TranslationError.unsupportedPair(src, tgt)
        let desc = error.errorDescription ?? ""
        #expect(desc.contains("en"))
        #expect(desc.contains("xx"))
    }

    @Test func allCasesHaveNonEmptyDescription() {
        let errors: [TranslationError] = [
            .timedOut,
            .sessionError(NSError(domain: "test", code: 0)),
            .unsupportedPair(Locale.Language(identifier: "en"), Locale.Language(identifier: "de"))
        ]
        for error in errors {
            let desc = error.errorDescription
            #expect(desc != nil, "Expected non-nil description for \(error)")
            #expect(!(desc ?? "").isEmpty, "Expected non-empty description for \(error)")
        }
    }

    @Test func equatableSameCasesAreEqual() {
        #expect(TranslationError.timedOut == TranslationError.timedOut)
        #expect(
            TranslationError.sessionError(NSError(domain: "a", code: 1)) ==
            TranslationError.sessionError(NSError(domain: "b", code: 2))
        )
    }

    @Test func equatableDifferentCasesNotEqual() {
        #expect(TranslationError.timedOut != TranslationError.sessionError(NSError(domain: "x", code: 0)))
    }
}

// MARK: - TranslationBridgeModel (state-only, no continuation)

@MainActor
struct TranslationBridgeModelStateTests {

    @Test func initialConfigurationIsNil() {
        let model = TranslationBridgeModel()
        #expect(model.configuration == nil)
    }
}

// MARK: - AppleTranslationService

@Suite("AppleTranslationService (F8.5.4)", .serialized) @MainActor
struct AppleTranslationServiceTests {

    @Test("translate goes through the direction's bridge model")
    func translateUsesModel() async throws {
        let model = TranslationBridgeModel()
        let driver = TranslationSessionDriver(model: model)
        defer { driver.stop() }
        let service = AppleTranslationService(model: model)
        let output = try await service.translate(text: "hola", from: Locale.Language(identifier: "es"),
                                                 to: Locale.Language(identifier: "en"))
        #expect(output == "EN:hola")
        #expect(service.engineName == "Apple Translation")
    }
}
