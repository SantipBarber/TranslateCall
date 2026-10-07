import Foundation
import Testing
@testable import TranslateCall

extension IntegrationTests {
    /// Prerequisites ask the framework whether a pack is *installed*; `supports` also accepts packs that
    /// are only downloadable (review finding: missing packs hung until the 300 s allowance).
    @Suite("Translation pack prerequisite")
    struct TranslationPackTests {
        @Test func unsupportedPairIsNotInstalled() async {
            #expect(await isTranslationPackInstalled(from: "en", to: "tlh") == false)
        }

        @Test func installedPairIsDetected() async {
            #expect(await isTranslationPackInstalled(from: "es", to: "en"))
        }

        @Test("AppleTranslationService.supports is the framework's answer (T5, REQ-TR-50)") @MainActor
        func appleSupportsMirrorsAvailability() async {
            let service = AppleTranslationService(model: TranslationBridgeModel())
            #expect(await service.supports(source: Locale.Language(identifier: "es"),
                                           target: Locale.Language(identifier: "en")))
            #expect(await service.supports(source: Locale.Language(identifier: "en"),
                                           target: Locale.Language(identifier: "tlh")) == false)
        }

        @Test("TranslationEngineSelector.supports asks the engine's service (REQ-TR-51)") @MainActor
        func selectorDelegatesToService() async {
            let selector = TranslationEngineSelector(outgoingBridge: TranslationBridgeModel(),
                                                     incomingBridge: TranslationBridgeModel())
            #expect(await selector.supports(source: Locale.Language(identifier: "es"),
                                            target: Locale.Language(identifier: "en")))
            #expect(await selector.supports(source: Locale.Language(identifier: "en"),
                                            target: Locale.Language(identifier: "tlh")) == false)
        }

        @Test("AppleTranslationService.isInstalled requires downloaded packs (REQ-TR-06)") @MainActor
        func appleIsInstalled() async {
            #expect(await AppleTranslationService.isInstalled(from: Locale.Language(identifier: "es"),
                                                              to: Locale.Language(identifier: "en")))
            #expect(await AppleTranslationService.isInstalled(from: Locale.Language(identifier: "en"),
                                                              to: Locale.Language(identifier: "tlh")) == false)
        }
    }
}
