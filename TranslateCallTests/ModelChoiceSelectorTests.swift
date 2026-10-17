import CoreAudio
import Foundation
import Testing
@testable import TranslateCall

/// Records which STT factory a selector used.
@MainActor
private final class STTPicks {
    var used: [String] = []
    func factory(_ name: String) -> (Locale) -> any SpeechRecognizerService {
        { [weak self] locale in self?.used.append(name); return MockSpeechRecognizerService(locale: locale) }
    }
}

@MainActor
private func freshDefaults() -> UserDefaults {
    let name = "ModelChoiceSelectorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
private func makeSTT(_ defaults: UserDefaults, _ picks: STTPicks, probe: ModelCacheProbe) -> STTEngineSelector {
    let selector = STTEngineSelector(defaults: defaults, appleSpeechFactory: picks.factory("apple"),
                                     parakeetFactory: picks.factory("parakeet"), whisperFactory: picks.factory("whisper"))
    selector.catalog = .builtIn
    selector.cacheProbe = probe
    return selector
}

@MainActor
private func makeTTS(_ defaults: UserDefaults, probe: ModelCacheProbe) -> TTSEngineSelector {
    let selector = TTSEngineSelector(defaults: defaults)
    selector.catalog = .builtIn
    selector.cacheProbe = probe
    selector.hasSystemVoice = { _ in true }
    selector.outputFactory = { _ in FakeOutput() }
    selector.avSpeechFactory = { FakeSynthesizer(engine: .avSpeech) }
    selector.kokoroFactory = { _ in FakeSynthesizer(engine: .kokoro) }
    selector.voiceCloneFactory = { _, _ in FakeSynthesizer(engine: .voiceClone) }
    selector.edgeFactory = { FakeSynthesizer(engine: .edgeTTS) }
    return selector
}

private let cachedAll = ModelCacheProbe(parakeet: { true }, whisper: { true }, kokoro: { true }, voiceClone: { false })

@Suite("Selectors in automatic mode (M9 UI core REQ-UI-21…23)") @MainActor
struct ModelChoiceSelectorTests {

    @Test("automatic is the default, for new and existing users")
    func automaticByDefault() {
        let defaults = freshDefaults()
        defaults.set("parakeet", forKey: "tlk.stt.engine")   // an existing manual choice
        let stt = makeSTT(defaults, STTPicks(), probe: .none)
        #expect(stt.isAutomatic)
        #expect(makeTTS(defaults, probe: .none).isAutomatic)
    }

    @Test("automatic STT uses the catalog with what is on disk, per direction")
    func automaticSTT() {
        let picks = STTPicks()
        let stt = makeSTT(freshDefaults(), picks, probe: cachedAll)
        _ = stt.makeOutgoingService(for: Locale(identifier: "en-US"))
        _ = stt.makeIncomingService(for: Locale(identifier: "en-US"))
        _ = stt.makeOutgoingService(for: Locale(identifier: "es-ES"))
        #expect(picks.used == ["parakeet", "whisper", "whisper"])
    }

    @Test("nothing on disk → Apple Speech, even if Parakeet was chosen by hand before")
    func automaticFallsBackToApple() {
        let picks = STTPicks()
        let defaults = freshDefaults()
        defaults.set("parakeet", forKey: "tlk.stt.engine")
        let stt = makeSTT(defaults, picks, probe: .none)
        _ = stt.makeOutgoingService(for: Locale(identifier: "en-US"))
        #expect(picks.used == ["apple"])
    }

    @Test("picking an engine by hand switches both selectors to manual; setAutomatic(true) switches back")
    func manualAndBack() {
        let defaults = freshDefaults()
        let picks = STTPicks()
        let stt = makeSTT(defaults, picks, probe: cachedAll)
        let tts = makeTTS(defaults, probe: cachedAll)

        stt.setPreferredEngine(.appleSpeech)
        #expect(!stt.isAutomatic && !tts.isAutomatic)
        _ = stt.makeOutgoingService(for: Locale(identifier: "en-US"))
        #expect(picks.used == ["apple"], "manual = today's behaviour")

        tts.setAutomatic(true)
        #expect(stt.isAutomatic)
        #expect(defaults.bool(forKey: ModelChoice.automaticKey))
    }

    @Test("automatic TTS: Kokoro for English when cached, the system voice otherwise")
    func automaticTTS() throws {
        let tts = makeTTS(freshDefaults(), probe: cachedAll)
        let english = try tts.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        let spanish = try tts.makeOutgoingService(for: Locale(identifier: "es-ES"), deviceID: nil)
        let incomingEnglish = try tts.makeIncomingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(english.primaryEngine == .kokoro)
        #expect(spanish.primaryEngine == .avSpeech)
        #expect(incomingEnglish.primaryEngine == .kokoro)
    }

    @Test("automatic TTS never picks Edge without prior consent (REQ-UI-22)")
    func automaticNeverEdgeWithoutConsent() throws {
        let tts = makeTTS(freshDefaults(), probe: .none)
        tts.hasSystemVoice = { _ in false }
        tts.edgeConsentGiven = { false }
        let service = try tts.makeOutgoingService(for: Locale(identifier: "uk-UA"), deviceID: nil)
        #expect(service.primaryEngine == .avSpeech)

        tts.edgeConsentGiven = { true }   // control: with consent, today's Edge fallback applies
        let consented = try tts.makeOutgoingService(for: Locale(identifier: "uk-UA"), deviceID: nil)
        #expect(consented.primaryEngine == .edgeTTS)
    }

    @Test("the voice clone is the automatic outgoing voice when on disk, enabled and with a profile (D-6)")
    func automaticVoiceCloneFromDisk() {
        let probe = ModelCacheProbe(parakeet: { false }, whisper: { false }, kokoro: { true }, voiceClone: { true })
        let tts = makeTTS(freshDefaults(), probe: probe)
        #expect(!tts.availability.voiceCloneReady, "not enabled, no profile")
        tts.voiceCloningEnabled = true
        tts.activeVoiceProfileId = UUID()
        #expect(tts.availability.voiceCloneReady, "loading is not required: on disk is enough")
        tts.cacheProbe = .none
        #expect(!tts.availability.voiceCloneReady)
    }
}
