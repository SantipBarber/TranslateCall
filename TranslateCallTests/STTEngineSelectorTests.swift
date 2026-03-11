import Foundation
import Testing
@testable import TranslateCall

// MARK: - STTEngineSelectorTests

/// Tests for `STTEngineSelector`.
///
/// All tests inject mock factories and a fresh `UserDefaults` suite so they
/// are hermetic and don't touch the real Parakeet model manager.
@Suite("STTEngineSelector")
@MainActor
struct STTEngineSelectorTests {

    // MARK: - Helpers

    static let suiteName = "STTEngineSelectorTests"

    /// Returns a fresh `UserDefaults` suite cleared before each test.
    func freshDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: STTEngineSelectorTests.suiteName)!
        suite.removePersistentDomain(forName: STTEngineSelectorTests.suiteName)
        return suite
    }

    /// Creates a selector with no-op Apple Speech and Parakeet factories and mock defaults.
    func makeSelector(
        defaults: UserDefaults? = nil,
        appleSpeechFactory: @escaping (Locale) -> any SpeechRecognizerService = { MockSpeechRecognizerService(locale: $0) },
        parakeetFactory: @escaping (Locale) -> any SpeechRecognizerService = { MockSpeechRecognizerService(locale: $0) }
    ) -> STTEngineSelector {
        STTEngineSelector(
            defaults: defaults ?? freshDefaults(),
            appleSpeechFactory: appleSpeechFactory,
            parakeetFactory: parakeetFactory
        )
    }

    // MARK: - Default engine

    @Test("Default engine is Apple Speech when no preference is stored")
    func defaultEngineIsAppleSpeech() {
        let selector = makeSelector()
        #expect(selector.preferredEngine == .appleSpeech)
    }

    // MARK: - Preference persistence

    @Test("setPreferredEngine persists to UserDefaults")
    func persistsEnginePreference() {
        let defaults = freshDefaults()
        let selector = makeSelector(defaults: defaults)
        selector.setPreferredEngine(.parakeet)
        #expect(defaults.string(forKey: "tlk.stt.engine") == "parakeet")
    }

    @Test("Selector restores engine from UserDefaults on init")
    func restoresEngineOnInit() {
        let defaults = freshDefaults()
        defaults.set("parakeet", forKey: "tlk.stt.engine")
        let selector = makeSelector(defaults: defaults)
        #expect(selector.preferredEngine == .parakeet)
    }

    @Test("Unknown stored value falls back to appleSpeech")
    func unknownStoredValueFallsBack() {
        let defaults = freshDefaults()
        defaults.set("unknownEngine", forKey: "tlk.stt.engine")
        let selector = makeSelector(defaults: defaults)
        #expect(selector.preferredEngine == .appleSpeech)
    }

    @Test("Changing preference updates preferredEngine property")
    func setPreferredEngineUpdatesProperty() {
        let selector = makeSelector()
        selector.setPreferredEngine(.parakeet)
        #expect(selector.preferredEngine == .parakeet)
        selector.setPreferredEngine(.appleSpeech)
        #expect(selector.preferredEngine == .appleSpeech)
    }

    // MARK: - Engine selection logic (makeOutgoingService)

    @Test("Apple Speech preference always uses AppleSpeechFactory for outgoing")
    func appleSpeechPreferenceUsesAppleFactory() {
        var appleCalled = false
        var parakeetCalled = false
        let selector = makeSelector(
            appleSpeechFactory: { locale in appleCalled = true; return MockSpeechRecognizerService(locale: locale) },
            parakeetFactory: { locale in parakeetCalled = true; return MockSpeechRecognizerService(locale: locale) }
        )
        _ = selector.makeOutgoingService(for: Locale(identifier: "en-US"))
        #expect(appleCalled)
        #expect(!parakeetCalled)
    }

    @Test("Parakeet preference with English locale and available model uses Parakeet factory")
    func parakeetEngineWithEnglishUsesParakeet() {
        var parakeetCalled = false
        let selector = makeSelector(
            parakeetFactory: { locale in parakeetCalled = true; return MockSpeechRecognizerService(locale: locale) }
        )
        selector.setPreferredEngine(.parakeet)
        // Simulate model becoming available
        selector.setParakeetAvailableForTesting(true)

        _ = selector.makeOutgoingService(for: Locale(identifier: "en-US"))
        #expect(parakeetCalled)
    }

    @Test("Parakeet preference with non-English locale falls back to Apple Speech")
    func parakeetPreferenceNonEnglishUsesApple() {
        var appleCalled = false
        var parakeetCalled = false
        let selector = makeSelector(
            appleSpeechFactory: { locale in appleCalled = true; return MockSpeechRecognizerService(locale: locale) },
            parakeetFactory: { locale in parakeetCalled = true; return MockSpeechRecognizerService(locale: locale) }
        )
        selector.setPreferredEngine(.parakeet)
        selector.setParakeetAvailableForTesting(true)

        _ = selector.makeOutgoingService(for: Locale(identifier: "fr-FR"))
        #expect(appleCalled)
        #expect(!parakeetCalled)
    }

    @Test("Parakeet preference without available model falls back to Apple Speech")
    func parakeetUnavailableFallsBackToApple() {
        var appleCalled = false
        var parakeetCalled = false
        let selector = makeSelector(
            appleSpeechFactory: { locale in appleCalled = true; return MockSpeechRecognizerService(locale: locale) },
            parakeetFactory: { locale in parakeetCalled = true; return MockSpeechRecognizerService(locale: locale) }
        )
        selector.setPreferredEngine(.parakeet)
        // parakeetAvailable stays false (default)

        _ = selector.makeOutgoingService(for: Locale(identifier: "en-US"))
        #expect(appleCalled)
        #expect(!parakeetCalled)
    }

    // MARK: - makeIncomingService

    @Test("Incoming service always uses Apple Speech factory")
    func incomingAlwaysAppleSpeech() {
        var appleCalled = false
        var parakeetCalled = false
        let selector = makeSelector(
            appleSpeechFactory: { locale in appleCalled = true; return MockSpeechRecognizerService(locale: locale) },
            parakeetFactory: { locale in parakeetCalled = true; return MockSpeechRecognizerService(locale: locale) }
        )
        selector.setPreferredEngine(.parakeet)
        selector.setParakeetAvailableForTesting(true)

        _ = selector.makeIncomingService(for: Locale(identifier: "en-US"))
        #expect(appleCalled)
        #expect(!parakeetCalled)
    }

    // MARK: - usingFallback

    @Test("usingFallback is false when Apple Speech is preferred")
    func usingFallbackFalseForAppleSpeech() {
        let selector = makeSelector()
        #expect(!selector.usingFallback)
    }

    @Test("usingFallback is false when Parakeet is available and source is English")
    func usingFallbackFalseWhenParakeetUsed() {
        let selector = makeSelector()
        selector.setPreferredEngine(.parakeet)
        selector.setParakeetAvailableForTesting(true)
        _ = selector.makeOutgoingService(for: Locale(identifier: "en-US"))
        #expect(!selector.usingFallback)
    }

    @Test("usingFallback is true when Parakeet preferred but source is not English")
    func usingFallbackTrueForNonEnglish() {
        let selector = makeSelector()
        selector.setPreferredEngine(.parakeet)
        selector.setParakeetAvailableForTesting(true)
        _ = selector.makeOutgoingService(for: Locale(identifier: "de-DE"))
        #expect(selector.usingFallback)
    }

    @Test("usingFallback is true when Parakeet preferred but model not available")
    func usingFallbackTrueWhenModelUnavailable() {
        let selector = makeSelector()
        selector.setPreferredEngine(.parakeet)
        // parakeetAvailable stays false
        _ = selector.makeOutgoingService(for: Locale(identifier: "en-US"))
        #expect(selector.usingFallback)
    }

    // MARK: - currentSourceLocale

    @Test("makeOutgoingService updates currentSourceLocale")
    func makeOutgoingServiceUpdatesCurrentLocale() {
        let selector = makeSelector()
        _ = selector.makeOutgoingService(for: Locale(identifier: "en-AU"))
        #expect(selector.currentSourceLocale == Locale(identifier: "en-AU"))
    }
}

// MARK: - Testing hook (avoids production code changes)

extension STTEngineSelector {
    /// Directly sets `parakeetAvailable` for testing purposes.
    ///
    /// This bypasses the `ParakeetModelManager` state stream, allowing hermetic unit tests
    /// that don't require a real model download.
    func setParakeetAvailableForTesting(_ available: Bool) {
        parakeetAvailable = available
    }
}
