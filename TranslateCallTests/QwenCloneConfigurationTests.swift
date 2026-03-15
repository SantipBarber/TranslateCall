import Foundation
import Testing
@testable import TranslateCall

// MARK: - QwenCloneConfigurationTests

@Suite("QwenCloneConfiguration")
@MainActor
struct QwenCloneConfigurationTests {

    @Test("Default model repo is 8-bit variant")
    func defaultModelRepo() {
        let config = QwenCloneConfiguration.default
        #expect(config.modelRepo == "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit")
    }

    @Test("Language mapping: English")
    func languageMappingEnglish() {
        let lang = QwenCloneConfiguration.language(for: Locale(identifier: "en-US"))
        #expect(lang == "english")
    }

    @Test("Language mapping: Spanish")
    func languageMappingSpanish() {
        let lang = QwenCloneConfiguration.language(for: Locale(identifier: "es-ES"))
        #expect(lang == "spanish")
    }

    @Test("supportsLocale: English")
    func supportsLocaleEnglish() {
        #expect(QwenCloneConfiguration.supportsLocale(Locale(identifier: "en-US")))
    }

    @Test("supportsLocale: Spanish")
    func supportsLocaleSpanish() {
        #expect(QwenCloneConfiguration.supportsLocale(Locale(identifier: "es-MX")))
    }

    @Test("Unsupported locale: Hindi")
    func unsupportedLocaleHindi() {
        #expect(!QwenCloneConfiguration.supportsLocale(Locale(identifier: "hi-IN")))
        #expect(QwenCloneConfiguration.language(for: Locale(identifier: "hi-IN")) == nil)
    }

    @Test("All supported languages count is 10")
    func allSupportedLanguagesCount() {
        #expect(QwenCloneConfiguration.supportedLanguageCount == 10)
    }
}
