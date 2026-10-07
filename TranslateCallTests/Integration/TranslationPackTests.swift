import Foundation
import Testing
@testable import TranslateCall

extension IntegrationTests {
    /// `TranslationService.supports` defaults to `true`, so tests must ask the framework directly
    /// whether a pack is installed (review finding: missing packs hung until the 300 s allowance).
    @Suite("Translation pack prerequisite")
    struct TranslationPackTests {
        @Test func unsupportedPairIsNotInstalled() async {
            #expect(await isTranslationPackInstalled(from: "en", to: "tlh") == false)
        }

        @Test func installedPairIsDetected() async {
            #expect(await isTranslationPackInstalled(from: "es", to: "en"))
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
