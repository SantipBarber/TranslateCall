import Foundation
import Testing
@testable import TranslateCall

// MARK: - TranslationEngine Tests

@Suite("TranslationEngine")
struct TranslationEngineTests {
    @Test func displayName() {
        #expect(TranslationEngine.appleTranslation.displayName == "Apple Translation")
    }

    @Test func rawValueRoundTrip() {
        let engine = TranslationEngine.appleTranslation
        #expect(TranslationEngine(rawValue: engine.rawValue) == engine)
    }

    @Test func allCasesContainsApple() {
        #expect(TranslationEngine.allCases.contains(.appleTranslation))
    }
}

// MARK: - TranslationError New Cases

@Suite("TranslationError new cases")
struct TranslationErrorNewCasesTests {
    @Test func networkUnavailableHasDescription() {
        let error = TranslationError.networkUnavailable
        #expect(error.errorDescription?.isEmpty == false)
    }

    @Test func modelNotLoadedHasDescription() {
        let error = TranslationError.modelNotLoaded
        #expect(error.errorDescription?.isEmpty == false)
    }

    @Test func networkUnavailableEquality() {
        #expect(TranslationError.networkUnavailable == TranslationError.networkUnavailable)
        #expect(TranslationError.networkUnavailable != TranslationError.modelNotLoaded)
    }
}

// MARK: - TranslationEngineSelector Tests

@Suite("TranslationEngineSelector")
@MainActor
struct TranslationEngineSelectorTests {
    @Test func defaultEngineIsApple() {
        let selector = TranslationEngineSelector(
            outgoingBridge: TranslationBridgeModel(),
            incomingBridge: TranslationBridgeModel(),
            defaults: UserDefaults(suiteName: "test.selector.default")!
        )
        #expect(selector.preferredEngine == .appleTranslation)
    }

    @Test func setPreferredEnginePersists() {
        let suite = "test.selector.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let outBridge = TranslationBridgeModel()
        let inBridge = TranslationBridgeModel()

        let selector1 = TranslationEngineSelector(
            outgoingBridge: outBridge, incomingBridge: inBridge, defaults: defaults
        )
        selector1.setPreferredEngine(.appleTranslation)

        let selector2 = TranslationEngineSelector(
            outgoingBridge: outBridge, incomingBridge: inBridge, defaults: defaults
        )
        #expect(selector2.preferredEngine == .appleTranslation)
    }

    @Test func makeOutgoingServiceReturnsAppleTranslation() {
        let selector = TranslationEngineSelector(
            outgoingBridge: TranslationBridgeModel(),
            incomingBridge: TranslationBridgeModel(),
            defaults: UserDefaults(suiteName: "test.selector.outgoing")!
        )
        let service = selector.makeOutgoingService()
        #expect(service.engineName == "Apple Translation")
    }

    @Test func makeIncomingServiceReturnsSeparateInstance() {
        let selector = TranslationEngineSelector(
            outgoingBridge: TranslationBridgeModel(),
            incomingBridge: TranslationBridgeModel(),
            defaults: UserDefaults(suiteName: "test.selector.incoming")!
        )
        let outgoing = selector.makeOutgoingService()
        let incoming = selector.makeIncomingService()
        #expect(outgoing !== incoming)
    }
}
