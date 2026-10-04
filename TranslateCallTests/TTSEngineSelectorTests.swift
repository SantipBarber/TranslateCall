import CoreAudio
import Foundation
import Testing
@testable import TranslateCall

// MARK: - TTSEngineSelectorTests

/// Tests for `TTSEngineSelector`.
///
/// All tests inject fake synthesizers, a fake output and a fresh `UserDefaults` suite, so they are
/// hermetic: no audio device, no model, no installed-voice dependency.
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

    func makeSelector(defaults: UserDefaults? = nil, systemVoice: @escaping (Locale) -> Bool = { _ in true }) -> TTSEngineSelector {
        let selector = TTSEngineSelector(defaults: defaults ?? freshDefaults())
        selector.hasSystemVoice = systemVoice
        selector.outputFactory = { _ in FakeOutput() }
        selector.avSpeechFactory = { FakeSynthesizer(engine: .avSpeech) }
        selector.kokoroFactory = { _ in FakeSynthesizer(engine: .kokoro) }
        selector.voiceCloneFactory = { _, _ in FakeSynthesizer(engine: .voiceClone) }
        selector.edgeFactory = { FakeSynthesizer(engine: .edgeTTS) }
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

    @Test("AVSpeech preference builds an AVSpeech primary with no fallback (REQ-T-22)")
    func avSpeechHasNoFallback() throws {
        let service = try makeSelector().makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(service.primaryEngine == .avSpeech)
        #expect(service.fallbackEngine == nil)
    }

    @Test("Kokoro preference, English, model available: Kokoro primary with the AVSpeech fallback (REQ-T-22)")
    func kokoroWithEnglish() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        selector.setKokoroAvailableForTesting(true)
        let service = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(service.primaryEngine == .kokoro)
        #expect(service.fallbackEngine == .avSpeech)
    }

    @Test("Kokoro preference with a non-English locale uses AVSpeech")
    func kokoroPreferenceNonEnglishUsesAVSpeech() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        selector.setKokoroAvailableForTesting(true)
        let service = try selector.makeOutgoingService(for: Locale(identifier: "fr-FR"), deviceID: nil)
        #expect(service.primaryEngine == .avSpeech)
    }

    @Test("Kokoro preference without the model uses AVSpeech")
    func kokoroUnavailableFallsBackToAVSpeech() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        let service = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(service.primaryEngine == .avSpeech)
    }

    @Test("Edge, Kokoro and the voice clone get the AVSpeech fallback only when the locale has a system voice")
    func fallbackNeedsSystemVoice() throws {
        let selector = makeSelector(systemVoice: { $0.language.languageCode?.identifier == "en" })
        selector.setPreferredEngine(.edgeTTS)
        #expect(try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil).fallbackEngine == .avSpeech)
        #expect(try selector.makeOutgoingService(for: Locale(identifier: "uk-UA"), deviceID: nil).fallbackEngine == nil)
    }

    @Test("the output is built for the device the coordinator passes")
    func outputGetsDevice() throws {
        let selector = makeSelector()
        var devices: [AudioDeviceID?] = []
        selector.outputFactory = { devices.append($0); return FakeOutput() }
        _ = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: 42)
        _ = try selector.makeIncomingService(for: Locale(identifier: "es-ES"), deviceID: nil)
        #expect(devices == [42, nil])
    }

    @Test("an output that cannot open makes the factory throw (the coordinator shows it)")
    func outputFailureThrows() {
        let selector = makeSelector()
        selector.outputFactory = { _ in throw STSError.deviceRoutingFailed }
        #expect(throws: STSError.deviceRoutingFailed) {
            _ = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: 42)
        }
    }

    // MARK: - makeIncomingService

    @Test("Incoming uses AVSpeech even when Kokoro is preferred")
    func incomingAlwaysAVSpeech() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        selector.setKokoroAvailableForTesting(true)
        let service = try selector.makeIncomingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(service.primaryEngine == .avSpeech)
        #expect(service.fallbackEngine == nil)
    }

    @Test("Incoming uses Edge when it is the preferred engine")
    func incomingEdgeWhenPreferred() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.edgeTTS)
        let service = try selector.makeIncomingService(for: Locale(identifier: "de-DE"), deviceID: nil)
        #expect(service.primaryEngine == .edgeTTS)
        #expect(service.fallbackEngine == .avSpeech)
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
