import CoreAudio
import Foundation
import Testing
@testable import TranslateCall

// MARK: - TTSEngineSelectorTests

/// Tests for `TTSEngineSelector`.
///
/// All tests inject mock factories and a fresh `UserDefaults` suite so they
/// are hermetic and don't touch the real Kokoro model manager.
@Suite("TTSEngineSelector")
@MainActor
struct TTSEngineSelectorTests {

    // MARK: - Helpers

    static let suiteName = "TTSEngineSelectorTests"

    func freshDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: TTSEngineSelectorTests.suiteName)!
        suite.removePersistentDomain(forName: TTSEngineSelectorTests.suiteName)
        return suite
    }

    func makeSelector(
        defaults: UserDefaults? = nil,
        avSpeechFactory: @escaping (AudioDeviceID?) throws -> any SynthesisService = { _ in MockSynthesisService() },
        kokoroFactory: @escaping (AudioDeviceID?, KokoroConfiguration) throws -> any SynthesisService = { _, _ in MockSynthesisService() }
    ) -> TTSEngineSelector {
        let selector = TTSEngineSelector(defaults: defaults ?? freshDefaults())
        selector.avSpeechFactory = avSpeechFactory
        selector.kokoroFactory = kokoroFactory
        return selector
    }

    // MARK: - Default engine

    @Test("Default engine is AVSpeech when no preference is stored")
    func defaultEngineIsAVSpeech() {
        let selector = makeSelector()
        #expect(selector.preferredEngine == .avSpeech)
    }

    // MARK: - Preference persistence

    @Test("setPreferredEngine persists to UserDefaults")
    func persistsEnginePreference() {
        let defaults = freshDefaults()
        let selector = makeSelector(defaults: defaults)
        selector.setPreferredEngine(.kokoro)
        #expect(defaults.string(forKey: "tlk.tts.engine") == "kokoro")
    }

    @Test("Selector restores engine from UserDefaults on init")
    func restoresEngineOnInit() {
        let defaults = freshDefaults()
        defaults.set("kokoro", forKey: "tlk.tts.engine")
        let selector = makeSelector(defaults: defaults)
        #expect(selector.preferredEngine == .kokoro)
    }

    @Test("Unknown stored value falls back to avSpeech")
    func unknownStoredValueFallsBack() {
        let defaults = freshDefaults()
        defaults.set("unknownEngine", forKey: "tlk.tts.engine")
        let selector = makeSelector(defaults: defaults)
        #expect(selector.preferredEngine == .avSpeech)
    }

    @Test("Changing preference updates preferredEngine property")
    func setPreferredEngineUpdatesProperty() {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        #expect(selector.preferredEngine == .kokoro)
        selector.setPreferredEngine(.avSpeech)
        #expect(selector.preferredEngine == .avSpeech)
    }

    // MARK: - makeOutgoingService

    @Test("AVSpeech preference always uses AVSpeech factory")
    func avSpeechPreferenceUsesAVSpeechFactory() throws {
        var avCalled = false
        var kokoroCalled = false
        let selector = makeSelector(
            avSpeechFactory: { _ in avCalled = true; return MockSynthesisService() },
            kokoroFactory: { _, _ in kokoroCalled = true; return MockSynthesisService() }
        )
        _ = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(avCalled)
        #expect(!kokoroCalled)
    }

    @Test("Kokoro preference with English locale and available model uses Kokoro factory")
    func kokoroEngineWithEnglishUsesKokoroFactory() throws {
        var kokoroCalled = false
        let selector = makeSelector(
            kokoroFactory: { _, _ in kokoroCalled = true; return MockSynthesisService() }
        )
        selector.setPreferredEngine(.kokoro)
        selector.setKokoroAvailableForTesting(true)

        _ = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(kokoroCalled)
    }

    @Test("Kokoro preference with non-English locale falls back to AVSpeech")
    func kokoroPreferenceNonEnglishUsesAVSpeech() throws {
        var avCalled = false
        var kokoroCalled = false
        let selector = makeSelector(
            avSpeechFactory: { _ in avCalled = true; return MockSynthesisService() },
            kokoroFactory: { _, _ in kokoroCalled = true; return MockSynthesisService() }
        )
        selector.setPreferredEngine(.kokoro)
        selector.setKokoroAvailableForTesting(true)

        _ = try selector.makeOutgoingService(for: Locale(identifier: "fr-FR"), deviceID: nil)
        #expect(avCalled)
        #expect(!kokoroCalled)
    }

    @Test("Kokoro preference without available model falls back to AVSpeech")
    func kokoroUnavailableFallsBackToAVSpeech() throws {
        var avCalled = false
        var kokoroCalled = false
        let selector = makeSelector(
            avSpeechFactory: { _ in avCalled = true; return MockSynthesisService() },
            kokoroFactory: { _, _ in kokoroCalled = true; return MockSynthesisService() }
        )
        selector.setPreferredEngine(.kokoro)
        // kokoroAvailable stays false (default)

        _ = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(avCalled)
        #expect(!kokoroCalled)
    }

    // MARK: - makeIncomingService

    @Test("Incoming service always uses AVSpeech factory")
    func incomingAlwaysAVSpeech() throws {
        var avCalled = false
        var kokoroCalled = false
        let selector = makeSelector(
            avSpeechFactory: { _ in avCalled = true; return MockSynthesisService() },
            kokoroFactory: { _, _ in kokoroCalled = true; return MockSynthesisService() }
        )
        selector.setPreferredEngine(.kokoro)
        selector.setKokoroAvailableForTesting(true)

        _ = try selector.makeIncomingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(avCalled)
        #expect(!kokoroCalled)
    }

    // MARK: - usingFallback

    @Test("usingFallback is false when AVSpeech is preferred")
    func usingFallbackFalseForAVSpeech() {
        let selector = makeSelector()
        #expect(!selector.usingFallback)
    }

    @Test("usingFallback is false when Kokoro is available and target is English")
    func usingFallbackFalseWhenKokoroUsed() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        selector.setKokoroAvailableForTesting(true)
        _ = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(!selector.usingFallback)
    }

    @Test("usingFallback is true when Kokoro preferred but target is not English")
    func usingFallbackTrueForNonEnglish() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        selector.setKokoroAvailableForTesting(true)
        _ = try selector.makeOutgoingService(for: Locale(identifier: "de-DE"), deviceID: nil)
        #expect(selector.usingFallback)
    }

    @Test("usingFallback is true when Kokoro preferred but model not available")
    func usingFallbackTrueWhenModelUnavailable() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        // kokoroAvailable stays false
        _ = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(selector.usingFallback)
    }

    // MARK: - currentTargetLocale

    @Test("makeOutgoingService updates currentTargetLocale")
    func makeOutgoingServiceUpdatesCurrentLocale() throws {
        let selector = makeSelector()
        _ = try selector.makeOutgoingService(for: Locale(identifier: "en-AU"), deviceID: nil)
        #expect(selector.currentTargetLocale == Locale(identifier: "en-AU"))
    }
}
