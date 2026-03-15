import Foundation
import Testing
@testable import TranslateCall

// MARK: - TTSEngineSelectorVoiceCloneTests

@Suite("TTSEngineSelector Voice Clone")
@MainActor
struct TTSEngineSelectorVoiceCloneTests {

    // MARK: - Helpers

    private func makeSelector() -> TTSEngineSelector {
        let defaults = UserDefaults(suiteName: "TTSEngineSelectorVoiceCloneTests.\(UUID())")!
        let selector = TTSEngineSelector(defaults: defaults)

        // Inject mock factories that don't require real audio hardware
        selector.avSpeechFactory = { _ in MockSynthesisService() }
        selector.kokoroFactory = { _, _ in MockSynthesisService() }
        selector.voiceCloneFactory = { _, _, _ in MockSynthesisService() }

        return selector
    }

    // MARK: - Tests

    @Test("voiceCloningActive requires all three conditions")
    func voiceCloningActiveRequiresAllThree() {
        let selector = makeSelector()

        // All false initially
        #expect(!selector.voiceCloningActive)

        // Enable but no model and no profile
        selector.voiceCloningEnabled = true
        #expect(!selector.voiceCloningActive)

        // Add model availability
        selector.setVoiceCloneAvailableForTesting(true)
        #expect(!selector.voiceCloningActive) // still no profile

        // Add profile
        selector.activeVoiceProfileId = UUID()
        #expect(selector.voiceCloningActive)
    }

    @Test("makeOutgoing returns voice clone when active and locale supported")
    func makeOutgoingReturnsVoiceCloneWhenActive() throws {
        let selector = makeSelector()
        selector.voiceCloningEnabled = true
        selector.setVoiceCloneAvailableForTesting(true)
        selector.activeVoiceProfileId = UUID()

        let store = MockVoiceProfileStore()
        selector.setProfileStore(store)

        // Spanish is supported by Qwen3-TTS
        let service = try selector.makeOutgoingService(
            for: Locale(identifier: "es-ES"),
            deviceID: nil
        )
        // Should have used voiceCloneFactory (returns MockSynthesisService)
        #expect(service is MockSynthesisService)
    }

    @Test("makeOutgoing falls back for unsupported locale")
    func makeOutgoingFallsBackForUnsupportedLocale() throws {
        let selector = makeSelector()
        selector.voiceCloningEnabled = true
        selector.setVoiceCloneAvailableForTesting(true)
        selector.activeVoiceProfileId = UUID()

        let store = MockVoiceProfileStore()
        selector.setProfileStore(store)

        // Hindi is not supported by Qwen3-TTS → falls back to AVSpeech
        let service = try selector.makeOutgoingService(
            for: Locale(identifier: "hi-IN"),
            deviceID: nil
        )
        #expect(service is MockSynthesisService)
    }

    @Test("makeOutgoing uses Kokoro when cloning disabled")
    func makeOutgoingUsesKokoroWhenCloningDisabled() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        selector.setKokoroAvailableForTesting(true)

        let service = try selector.makeOutgoingService(
            for: Locale(identifier: "en-US"),
            deviceID: nil
        )
        #expect(service is MockSynthesisService)
    }

    @Test("Voice Clone supports Spanish, French, and other languages")
    func voiceCloneSupportsMultipleLanguages() {
        #expect(TTSEngine.voiceClone.supports(locale: Locale(identifier: "es-ES")))
        #expect(TTSEngine.voiceClone.supports(locale: Locale(identifier: "fr-FR")))
        #expect(TTSEngine.voiceClone.supports(locale: Locale(identifier: "de-DE")))
        #expect(TTSEngine.voiceClone.supports(locale: Locale(identifier: "it-IT")))
        #expect(TTSEngine.voiceClone.supports(locale: Locale(identifier: "pt-BR")))
        #expect(TTSEngine.voiceClone.supports(locale: Locale(identifier: "ru-RU")))
        #expect(TTSEngine.voiceClone.supports(locale: Locale(identifier: "zh-Hans")))
        #expect(TTSEngine.voiceClone.supports(locale: Locale(identifier: "ja-JP")))
        #expect(TTSEngine.voiceClone.supports(locale: Locale(identifier: "ko-KR")))
        #expect(!TTSEngine.voiceClone.supports(locale: Locale(identifier: "hi-IN")))
        #expect(!TTSEngine.voiceClone.supports(locale: Locale(identifier: "ar-SA")))
    }
}
