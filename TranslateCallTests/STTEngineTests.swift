import Foundation
import Testing
@testable import TranslateCall

// MARK: - STTEngine

@Suite("STTEngine")
@MainActor
struct STTEngineTests {

    // MARK: - supports(locale:)

    @Test("Parakeet supports en-US")
    func parakeetSupportsEnglishUS() {
        #expect(STTEngine.parakeet.supports(locale: Locale(identifier: "en-US")))
    }

    @Test("Parakeet supports en-GB")
    func parakeetSupportsEnglishGB() {
        #expect(STTEngine.parakeet.supports(locale: Locale(identifier: "en-GB")))
    }

    @Test("Parakeet supports en (bare language code)")
    func parakeetSupportsBareEnglish() {
        #expect(STTEngine.parakeet.supports(locale: Locale(identifier: "en")))
    }

    @Test("Parakeet rejects fr-FR")
    func parakeetRejectsFrench() {
        #expect(!STTEngine.parakeet.supports(locale: Locale(identifier: "fr-FR")))
    }

    @Test("Parakeet rejects de-DE")
    func parakeetRejectsGerman() {
        #expect(!STTEngine.parakeet.supports(locale: Locale(identifier: "de-DE")))
    }

    @Test("Parakeet rejects zh-Hans")
    func parakeetRejectsChinese() {
        #expect(!STTEngine.parakeet.supports(locale: Locale(identifier: "zh-Hans")))
    }

    @Test("Apple Speech supports all languages")
    func appleSpeechSupportsAll() {
        let locales = ["en-US", "fr-FR", "de-DE", "zh-Hans", "ja-JP", "ar-SA"]
        for id in locales {
            #expect(STTEngine.appleSpeech.supports(locale: Locale(identifier: id)),
                    "Expected Apple Speech to support \(id)")
        }
    }

    // MARK: - Codable / rawValue

    @Test("rawValue round-trip: appleSpeech")
    func rawValueRoundTripAppleSpeech() {
        #expect(STTEngine(rawValue: "appleSpeech") == .appleSpeech)
    }

    @Test("rawValue round-trip: parakeet")
    func rawValueRoundTripParakeet() {
        #expect(STTEngine(rawValue: "parakeet") == .parakeet)
    }

    @Test("Unknown rawValue returns nil")
    func unknownRawValueReturnsNil() {
        #expect(STTEngine(rawValue: "unknown") == nil)
    }

    @Test("CaseIterable covers both cases")
    func allCasesCount() {
        #expect(STTEngine.allCases == [.appleSpeech, .parakeet, .whisper])
    }

    @Test("displayName is non-empty for all cases")
    func displayNamesNonEmpty() {
        for engine in STTEngine.allCases {
            #expect(!engine.displayName.isEmpty, "\(engine) has empty displayName")
        }
    }
}

// MARK: - Locale.isEnglish

@Suite("Locale.isEnglish")
@MainActor
struct LocaleIsEnglishTests {

    @Test("en-US is English")
    func enUSIsEnglish() {
        #expect(Locale(identifier: "en-US").isEnglish)
    }

    @Test("en is English")
    func enIsEnglish() {
        #expect(Locale(identifier: "en").isEnglish)
    }

    @Test("fr-FR is not English")
    func frFRNotEnglish() {
        #expect(!Locale(identifier: "fr-FR").isEnglish)
    }

    @Test("de-DE is not English")
    func deNotEnglish() {
        #expect(!Locale(identifier: "de-DE").isEnglish)
    }

    @Test("zh-Hans is not English")
    func zhNotEnglish() {
        #expect(!Locale(identifier: "zh-Hans").isEnglish)
    }
}
