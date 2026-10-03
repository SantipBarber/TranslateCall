import Foundation
import Testing
@testable import TranslateCall

// MARK: - TTSEngineTests

@Suite("TTSEngine")
@MainActor
struct TTSEngineTests {

    // MARK: - supports(locale:)

    @Test("Kokoro supports en-US")
    func kokoroSupportsEnglishUS() {
        #expect(TTSEngine.kokoro.supports(locale: Locale(identifier: "en-US")))
    }

    @Test("Kokoro supports en-GB")
    func kokoroSupportsEnglishGB() {
        #expect(TTSEngine.kokoro.supports(locale: Locale(identifier: "en-GB")))
    }

    @Test("Kokoro supports en (bare language code)")
    func kokoroSupportsBareEnglish() {
        #expect(TTSEngine.kokoro.supports(locale: Locale(identifier: "en")))
    }

    @Test("Kokoro rejects fr-FR")
    func kokoroRejectsFrench() {
        #expect(!TTSEngine.kokoro.supports(locale: Locale(identifier: "fr-FR")))
    }

    @Test("Kokoro rejects de-DE")
    func kokoroRejectsGerman() {
        #expect(!TTSEngine.kokoro.supports(locale: Locale(identifier: "de-DE")))
    }

    @Test("Kokoro rejects zh-Hans")
    func kokoroRejectsChinese() {
        #expect(!TTSEngine.kokoro.supports(locale: Locale(identifier: "zh-Hans")))
    }

    @Test("AVSpeech supports all languages")
    func avSpeechSupportsAll() {
        let locales = ["en-US", "fr-FR", "de-DE", "zh-Hans", "ja-JP", "ar-SA"]
        for id in locales {
            #expect(TTSEngine.avSpeech.supports(locale: Locale(identifier: id)),
                    "Expected AVSpeech to support \(id)")
        }
    }

    // MARK: - Voice Clone

    @Test("Voice Clone supports en-US")
    func voiceCloneSupportsEnglishUS() {
        #expect(TTSEngine.voiceClone.supports(locale: Locale(identifier: "en-US")))
    }

    // MARK: - Codable / rawValue

    @Test("rawValue round-trip: avSpeech")
    func rawValueRoundTripAVSpeech() {
        #expect(TTSEngine(rawValue: "avSpeech") == .avSpeech)
    }

    @Test("rawValue round-trip: kokoro")
    func rawValueRoundTripKokoro() {
        #expect(TTSEngine(rawValue: "kokoro") == .kokoro)
    }

    @Test("rawValue round-trip: voiceClone")
    func rawValueRoundTripVoiceClone() {
        #expect(TTSEngine(rawValue: "voiceClone") == .voiceClone)
    }

    @Test("Unknown rawValue returns nil")
    func unknownRawValueReturnsNil() {
        #expect(TTSEngine(rawValue: "unknown") == nil)
    }

    @Test("CaseIterable covers all cases")
    func allCasesCount() {
        #expect(TTSEngine.allCases == [.avSpeech, .kokoro, .voiceClone, .edgeTTS])
    }

    @Test("displayName is non-empty for all cases")
    func displayNamesNonEmpty() {
        for engine in TTSEngine.allCases {
            #expect(!engine.displayName.isEmpty, "\(engine) has empty displayName")
        }
    }

    @Test("voiceClone displayName is Voice Clone")
    func voiceCloneDisplayName() {
        #expect(TTSEngine.voiceClone.displayName == "Voice Clone")
    }
}
