import CoreAudio
import Foundation
import Testing
@testable import TranslateCall

// MARK: - TTSEngineSelectorTests

/// `TTSEngineSelector` playback composition and resolution through the pair choice (M9 UI settings
/// REQ-ST-02…04). Fake synthesizers and output, a fresh `UserDefaults` suite, injected disk checks: no
/// audio device, no model, no installed-voice dependency.
@Suite("TTSEngineSelector")
@MainActor
struct TTSEngineSelectorTests {

    private let kokoroOnDisk = ModelCacheProbe(parakeet: { false }, whisper: { false }, kokoro: { true },
                                               voiceClone: { true })

    func makeSelector(systemVoice: @escaping (Locale) -> Bool = { _ in true },
                      probe: ModelCacheProbe = .none, choice: PairModelChoice = PairModelChoice()) -> TTSEngineSelector {
        let selector = TTSEngineSelector(defaults: UserDefaults(suiteName: "TTSEngineSelectorTests.\(UUID())")!)
        selector.catalog = .builtIn
        selector.cacheProbe = probe
        selector.pairChoice = { choice }
        selector.hasSystemVoice = systemVoice
        selector.outputFactory = { _ in FakeOutput() }
        selector.avSpeechFactory = { FakeSynthesizer(engine: .avSpeech) }
        selector.kokoroFactory = { _ in FakeSynthesizer(engine: .kokoro) }
        selector.voiceCloneFactory = { _, _ in FakeSynthesizer(engine: .voiceClone) }
        selector.edgeFactory = { FakeSynthesizer(engine: .edgeTTS) }
        return selector
    }

    @Test("nothing on disk: AVSpeech primary with no fallback (REQ-T-22)")
    func avSpeechHasNoFallback() throws {
        let service = try makeSelector().makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(service.primaryEngine == .avSpeech)
        #expect(service.fallbackEngine == nil)
    }

    @Test("recommended: Kokoro for English when on disk, both directions, with the AVSpeech fallback")
    func kokoroRecommendedForEnglish() throws {
        let selector = makeSelector(probe: kokoroOnDisk)
        let outgoing = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(outgoing.primaryEngine == .kokoro)
        #expect(outgoing.fallbackEngine == .avSpeech)
        #expect(try selector.makeIncomingService(for: Locale(identifier: "en-US"), deviceID: nil).primaryEngine
                == .kokoro)
        #expect(try selector.makeOutgoingService(for: Locale(identifier: "es-ES"), deviceID: nil).primaryEngine
                == .avSpeech)
    }

    @Test("a pair's voice choice overrides the recommendation in both directions")
    func pairChoiceOverrides() throws {
        let selector = makeSelector(probe: kokoroOnDisk, choice: PairModelChoice(voice: .avSpeech))
        #expect(try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil).primaryEngine
                == .avSpeech)
        #expect(try selector.makeIncomingService(for: Locale(identifier: "en-US"), deviceID: nil).primaryEngine
                == .avSpeech)
    }

    @Test("the voice clone is the outgoing voice when on disk, enabled and with a profile (REQ-ST-04)")
    func voiceCloneOutgoing() throws {
        let selector = makeSelector(probe: kokoroOnDisk, choice: PairModelChoice(voice: .kokoro))
        selector.setProfileStore(MockVoiceProfileStore())
        #expect(!selector.availability.voiceCloneReady, "not enabled, no profile")
        selector.voiceCloningEnabled = true
        selector.activeVoiceProfileId = UUID()
        #expect(selector.availability.voiceCloneReady, "on disk is enough; loading is not required")
        #expect(try selector.makeOutgoingService(for: Locale(identifier: "es-ES"), deviceID: nil).primaryEngine
                == .voiceClone)
        #expect(try selector.makeIncomingService(for: Locale(identifier: "en-US"), deviceID: nil).primaryEngine
                == .avSpeech, "Kokoro is blocked while the voice clone is ready (NF-04)")
    }

    @Test("a voice clone with no profile store falls back to the system voice")
    func voiceCloneWithoutStore() throws {
        let selector = makeSelector(probe: kokoroOnDisk)
        selector.voiceCloningEnabled = true
        selector.activeVoiceProfileId = UUID()
        #expect(try selector.makeOutgoingService(for: Locale(identifier: "es-ES"), deviceID: nil).primaryEngine
                == .avSpeech)
    }

    @Test("Edge as the pair's choice gets the AVSpeech fallback only when the locale has a system voice")
    func fallbackNeedsSystemVoice() throws {
        let selector = makeSelector(systemVoice: { $0.language.languageCode?.identifier == "en" },
                                    choice: PairModelChoice(voice: .edgeTTS))
        selector.catalog = ModelCatalog(version: 2, stt: [:], ttsOutgoing: ["default": ["avSpeech"]],
                                        ttsIncoming: ["default": ["avSpeech"]])
        selector.cloudAllowed = { true }
        selector.edgeConsentGiven = { true }
        let english = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(english.primaryEngine == .edgeTTS)
        #expect(english.fallbackEngine == .avSpeech)
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

    @Test("makeOutgoingService updates currentTargetLocale")
    func makeOutgoingServiceUpdatesCurrentLocale() throws {
        let selector = makeSelector()
        _ = try selector.makeOutgoingService(for: Locale(identifier: "en-AU"), deviceID: nil)
        #expect(selector.currentTargetLocale == Locale(identifier: "en-AU"))
    }

    @Test("\"Use my voice\" with the model not loaded starts the download through ModelDownloads (S-4)")
    func enableVoiceCloningStartsDownload() {
        let selector = makeSelector()
        var started = 0
        selector.startVoiceCloneDownload = { started += 1 }
        selector.enableVoiceCloning()
        #expect(selector.voiceCloningEnabled)
        #expect(started == 1)
    }

    @Test("\"Use my voice\" during a session changes nothing and starts no download (S-7)")
    func enableVoiceCloningBlockedDuringSession() {
        let selector = makeSelector()
        var started = 0
        selector.startVoiceCloneDownload = { started += 1 }
        selector.downloadsBlocked = { true }
        selector.enableVoiceCloning()
        #expect(!selector.voiceCloningEnabled)
        #expect(started == 0)
    }

    @Test("Voice Clone supports Spanish, French, and other languages")
    func voiceCloneSupportsMultipleLanguages() {
        for code in ["es-ES", "fr-FR", "de-DE", "it-IT", "pt-BR", "ru-RU", "zh-Hans", "ja-JP", "ko-KR"] {
            #expect(TTSEngine.voiceClone.supports(locale: Locale(identifier: code)))
        }
        #expect(!TTSEngine.voiceClone.supports(locale: Locale(identifier: "hi-IN")))
        #expect(!TTSEngine.voiceClone.supports(locale: Locale(identifier: "ar-SA")))
    }

    @Test("the standard voice engine ignores the voice clone: Kokoro stays blocked while it is ready")
    func standardEngineIgnoresTheClone() {
        let selector = makeSelector(probe: kokoroOnDisk)
        let english = Locale(identifier: "en-US")
        selector.setProfileStore(MockVoiceProfileStore())
        selector.voiceCloningEnabled = true
        selector.activeVoiceProfileId = UUID()
        #expect(selector.standardEngine(for: english, direction: .outgoing) == .avSpeech)
        #expect(selector.standardEngine(for: Locale(identifier: "es-ES"), direction: .outgoing) == .avSpeech)
        #expect(selector.standardEngine(for: english, direction: .incoming) == .avSpeech)
        selector.voiceCloningEnabled = false
        #expect(selector.standardEngine(for: english, direction: .outgoing) == .kokoro)
    }
}
