@_exported import Testing
import Foundation
@testable import TranslateCall

// MARK: - TranslationError

@MainActor
struct TranslationErrorTests {

    @Test func bridgeUnavailableHasDescription() {
        let error = TranslationError.bridgeUnavailable
        #expect(error.errorDescription != nil)
        #expect(!error.errorDescription!.isEmpty)
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
            .bridgeUnavailable,
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
        #expect(TranslationError.bridgeUnavailable == TranslationError.bridgeUnavailable)
        #expect(
            TranslationError.sessionError(NSError(domain: "a", code: 1)) ==
            TranslationError.sessionError(NSError(domain: "b", code: 2))
        )
    }

    @Test func equatableDifferentCasesNotEqual() {
        #expect(TranslationError.bridgeUnavailable != TranslationError.sessionError(NSError(domain: "x", code: 0)))
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

// MARK: - AppleTranslationService (bridgeUnavailable path — no window needed)

@Suite(.serialized) @MainActor
struct AppleTranslationServiceTests {

    @Test func translateThrowsBridgeUnavailableWhenModelDeallocated() async {
        let service: AppleTranslationService
        do {
            let model = TranslationBridgeModel()
            service = AppleTranslationService(model: model)
        }
        // model is now deallocated — weak ref should be nil
        await #expect(throws: TranslationError.bridgeUnavailable) {
            try await service.translate(
                text: "hello",
                from: Locale.Language(identifier: "en"),
                to: Locale.Language(identifier: "es")
            )
        }
    }

    @Test func prepareThrowsBridgeUnavailableWhenModelDeallocated() async {
        let service: AppleTranslationService
        do {
            let model = TranslationBridgeModel()
            service = AppleTranslationService(model: model)
        }
        await #expect(throws: TranslationError.bridgeUnavailable) {
            try await service.prepare(
                source: Locale.Language(identifier: "en"),
                target: Locale.Language(identifier: "es")
            )
        }
    }
}
