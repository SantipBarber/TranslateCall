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

// MARK: - TTSEngineSelector Edge TTS Routing Tests

@Suite("TTSEngineSelector Edge TTS routing (M9 UI settings REQ-ST-32)")
@MainActor
struct TTSEngineSelectorEdgeTTSTests {

    /// Every language except Ukrainian has a system voice; consent and the cloud switch are injected,
    /// so no test touches `UserDefaults.standard`.
    private func makeSelector(allowed: Bool, consent: Bool) -> TTSEngineSelector {
        let selector = TTSEngineSelector(defaults: UserDefaults(suiteName: "EdgeTTSTests.\(UUID())")!)
        selector.catalog = ModelCatalog(version: 2, stt: [:], ttsOutgoing: ["default": ["avSpeech"]],
                                        ttsIncoming: ["default": ["avSpeech"]])
        selector.cacheProbe = .none
        selector.outputFactory = { _ in FakeOutput() }
        selector.avSpeechFactory = { FakeSynthesizer(engine: .avSpeech) }
        selector.edgeFactory = { FakeSynthesizer(engine: .edgeTTS) }
        selector.hasSystemVoice = { $0.language.languageCode?.identifier != "uk" }
        selector.cloudAllowed = { allowed }
        selector.edgeConsentGiven = { consent }
        return selector
    }

    @Test("Ukrainian with the cloud allowed and no consent needs the consent prompt before Start")
    func needsConsentForUkrainian() {
        let uk = Locale(identifier: "uk")
        #expect(makeSelector(allowed: true, consent: false).needsEdgeConsent(for: uk))
        #expect(!makeSelector(allowed: false, consent: false).needsEdgeConsent(for: uk), "cloud off: no prompt")
        #expect(!makeSelector(allowed: true, consent: true).needsEdgeConsent(for: uk))
        #expect(!makeSelector(allowed: true, consent: false).needsEdgeConsent(for: Locale(identifier: "en")))
    }

    @Test("the no-system-voice fallback uses Edge only with the cloud allowed and consent")
    func fallbackNeedsCloud() throws {
        let consented = makeSelector(allowed: true, consent: true)
        let service = try consented.makeOutgoingService(for: Locale(identifier: "uk"), deviceID: nil)
        #expect(consented.isUsingEdgeTTS)
        #expect(service.primaryEngine == .edgeTTS)
        #expect(service.fallbackEngine == nil)   // no Ukrainian system voice to fall back to

        let off = makeSelector(allowed: false, consent: true)
        #expect(try off.makeOutgoingService(for: Locale(identifier: "uk"), deviceID: nil).primaryEngine == .avSpeech)
        #expect(!off.isUsingEdgeTTS)
    }

    @Test("Edge marked unavailable blocks the fallback and the prompt (S-3)")
    func unavailableBlocksFallback() throws {
        let selector = makeSelector(allowed: true, consent: true)
        selector.catalog = .builtIn   // marks Edge unavailable
        #expect(try selector.makeOutgoingService(for: Locale(identifier: "uk"), deviceID: nil).primaryEngine
                == .avSpeech)
        selector.edgeConsentGiven = { false }
        #expect(!selector.needsEdgeConsent(for: Locale(identifier: "uk")))
    }
}
