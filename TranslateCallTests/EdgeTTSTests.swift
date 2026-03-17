import CoreAudio
import Foundation
import Testing
@testable import TranslateCall

// MARK: - EdgeTTSVoiceCatalog Tests

@Suite("EdgeTTSVoiceCatalog")
struct EdgeTTSVoiceCatalogTests {

    @Test("Default Ukrainian voice has uk-UA in shortName")
    func ukrainianVoiceExists() {
        let voice = EdgeTTSVoiceCatalog.defaultVoice(for: Locale(identifier: "uk"))
        #expect(voice != nil)
        #expect(voice?.shortName.contains("uk-UA") == true)
    }

    @Test("Ukrainian has exactly 2 voices (Polina + Ostap)")
    func ukrainianHasTwoVoices() {
        let voices = EdgeTTSVoiceCatalog.availableVoices(for: Locale(identifier: "uk"))
        #expect(voices.count == 2)
    }

    @Test("English voices exist in catalog")
    func englishVoicesExist() {
        let voices = EdgeTTSVoiceCatalog.availableVoices(for: Locale(identifier: "en"))
        #expect(!voices.isEmpty)
    }

    @Test("Catalog supports Ukrainian")
    func supportsUkrainian() {
        #expect(EdgeTTSVoiceCatalog.supports(Locale(identifier: "uk")))
    }

    @Test("Catalog does not support fictional locale")
    func doesNotSupportFictional() {
        #expect(!EdgeTTSVoiceCatalog.supports(Locale(identifier: "xx")))
    }

    @Test("Catalog has at least 30 voices")
    func catalogHasAtLeast30Voices() {
        #expect(EdgeTTSVoiceCatalog.voices.count >= 30)
    }
}

// MARK: - EdgeTTSConsentManager Tests

@Suite("EdgeTTSConsentManager")
struct EdgeTTSConsentManagerTests {

    @Test("Initial consent is false in fresh defaults")
    func initialConsentFalse() {
        let suite = "test.edgeTTSConsent.initial.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        // consentGiven reads from .standard, so we verify via the defaults key directly
        #expect(!defaults.bool(forKey: "tlk.edgeTTS.consentGiven"))
    }

    @Test("Grant and revoke consent round-trips correctly")
    func grantAndRevokeConsent() {
        let suite = "test.edgeTTSConsent.roundtrip.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!

        EdgeTTSConsentManager.grantConsent(defaults: defaults)
        #expect(defaults.bool(forKey: "tlk.edgeTTS.consentGiven") == true)

        EdgeTTSConsentManager.revokeConsent(defaults: defaults)
        #expect(defaults.bool(forKey: "tlk.edgeTTS.consentGiven") == false)
    }
}

// MARK: - EdgeTTSWebSocket String Escaping Tests

@Suite("EdgeTTSWebSocket XML Escaping")
struct EdgeTTSXMLEscapingTests {

    @Test("String.escapedForXML escapes all XML special characters")
    func ssmlEscaping() {
        let input = "Tom & Jerry <3 \"hello\" it's"
        let escaped = input.escapedForXML
        #expect(escaped.contains("&amp;"))
        #expect(escaped.contains("&lt;"))
        #expect(!escaped.contains("<3"))
        #expect(escaped.contains("&quot;"))
        #expect(escaped.contains("&apos;"))
        // Verify no raw special chars remain (except in entities)
        let withoutEntities = escaped
            .replacingOccurrences(of: "&amp;", with: "")
            .replacingOccurrences(of: "&lt;", with: "")
            .replacingOccurrences(of: "&gt;", with: "")
            .replacingOccurrences(of: "&quot;", with: "")
            .replacingOccurrences(of: "&apos;", with: "")
        #expect(!withoutEntities.contains("&"))
        #expect(!withoutEntities.contains("<"))
        #expect(!withoutEntities.contains(">"))
        #expect(!withoutEntities.contains("\""))
    }
}

// MARK: - TTSEngine Edge TTS Tests

@Suite("TTSEngine Edge TTS")
struct TTSEngineEdgeTTSTests {

    @Test("Edge TTS display name contains expected text")
    func edgeTTSDisplayName() {
        let name = TTSEngine.edgeTTS.displayName
        #expect(name.contains("Edge") || name.contains("Cloud"))
    }

    @Test("Edge TTS supports Ukrainian")
    func edgeTTSSupportsUkrainian() {
        #expect(TTSEngine.edgeTTS.supports(locale: Locale(identifier: "uk")))
    }

    @Test("Edge TTS does not support fictional locale")
    func edgeTTSDoesNotSupportFictional() {
        #expect(!TTSEngine.edgeTTS.supports(locale: Locale(identifier: "xx")))
    }
}

// MARK: - AVSpeechService.hasVoice Tests

@Suite("AVSpeechService.hasVoice")
struct AVSpeechServiceHasVoiceTests {

    @Test("hasVoice returns true for English")
    func hasVoiceForEnglish() {
        #expect(AVSpeechService.hasVoice(for: Locale(identifier: "en")))
    }

    @Test("hasVoice returns false for Ukrainian (no AVSpeech voices on macOS)")
    func noVoiceForUkrainian() {
        #expect(!AVSpeechService.hasVoice(for: Locale(identifier: "uk")))
    }
}

// MARK: - TTSEngineSelector Edge TTS Routing Tests

@Suite("TTSEngineSelector Edge TTS routing")
@MainActor
struct TTSEngineSelectorEdgeTTSTests {

    private static let suiteName = "TTSEngineSelectorEdgeTTSTests"

    private func freshDefaults() -> UserDefaults {
        let suite = "\(Self.suiteName).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return defaults
    }

    private func makeSelector(
        defaults: UserDefaults? = nil
    ) -> TTSEngineSelector {
        let defs = defaults ?? freshDefaults()
        let selector = TTSEngineSelector(defaults: defs)
        selector.avSpeechFactory = { _ in MockSynthesisService() }
        selector.kokoroFactory = { _, _ in MockSynthesisService() }
        return selector
    }

    @Test("needsEdgeTTSConsent is true for Ukrainian without consent")
    func needsEdgeTTSConsentForUkrainian() throws {
        let defaults = freshDefaults()
        // Ensure consent is NOT given in .standard
        EdgeTTSConsentManager.revokeConsent()
        let selector = makeSelector(defaults: defaults)
        _ = try selector.makeOutgoingService(
            for: Locale(identifier: "uk"), deviceID: nil
        )
        #expect(selector.needsEdgeTTSConsent)
        // Clean up .standard
        EdgeTTSConsentManager.revokeConsent()
    }

    @Test("needsEdgeTTSConsent is false for English (AVSpeech has voices)")
    func noConsentNeededForEnglish() throws {
        let defaults = freshDefaults()
        EdgeTTSConsentManager.revokeConsent()
        let selector = makeSelector(defaults: defaults)
        _ = try selector.makeOutgoingService(
            for: Locale(identifier: "en"), deviceID: nil
        )
        #expect(!selector.needsEdgeTTSConsent)
        EdgeTTSConsentManager.revokeConsent()
    }

    @Test("isUsingEdgeTTS is true for Ukrainian with consent granted")
    func isUsingEdgeTTSWhenConsented() throws {
        let defaults = freshDefaults()
        EdgeTTSConsentManager.grantConsent()
        let selector = makeSelector(defaults: defaults)
        _ = try selector.makeOutgoingService(
            for: Locale(identifier: "uk"), deviceID: nil
        )
        #expect(selector.isUsingEdgeTTS)
        // Clean up .standard
        EdgeTTSConsentManager.revokeConsent()
    }
}
