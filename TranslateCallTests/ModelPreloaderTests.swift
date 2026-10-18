import Combine
import Foundation
import Synchronization
import Testing
@testable import TranslateCall

/// Records load/unload calls in order; models in `failing` fail to load.
private final class LoaderLog: Sendable {
    private let calls = Mutex<[String]>([])
    let failing = Mutex<Set<PreloadModel>>([])
    var entries: [String] { calls.withLock { $0 } }
    var loaders: ModelLoaders {
        ModelLoaders(load: { model in
                         self.calls.withLock { $0.append("load \(model)") }
                         return !self.failing.withLock { $0.contains(model) }
                     },
                     unload: { model in self.calls.withLock { $0.append("unload \(model)") } })
    }
}

@MainActor
private struct Harness {
    let defaults: UserDefaults
    let stt: STTEngineSelector
    let tts: TTSEngineSelector
    let pair: LanguagePairManager
    let log = LoaderLog()

    init(source: String, target: String, probe: ModelCacheProbe) {
        let name = "ModelPreloaderTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(source, forKey: "tlk.source.language")
        defaults.set(target, forKey: "tlk.target.language")
        stt = STTEngineSelector(appleSpeechFactory: { MockSpeechRecognizerService(locale: $0) },
                                parakeetFactory: { MockSpeechRecognizerService(locale: $0) },
                                whisperFactory: { MockSpeechRecognizerService(locale: $0) })
        tts = TTSEngineSelector(defaults: defaults)
        stt.catalog = .builtIn
        stt.cacheProbe = probe
        tts.catalog = .builtIn
        tts.cacheProbe = probe
        pair = LanguagePairManager(defaults: defaults, languageLoader: { [] })
    }

    func preloader(sessionActive: @escaping () -> Bool = { false }) -> ModelPreloader {
        ModelPreloader(stt: stt, tts: tts, languagePairManager: pair, loaders: log.loaders, isSessionActive: sessionActive)
    }
}

private let cachedAll = ModelCacheProbe(parakeet: { true }, whisper: { true }, kokoro: { true }, voiceClone: { true })

@Suite("ModelPreloader (M9 UI core REQ-UI-21a)", .serialized) @MainActor
struct ModelPreloaderTests {

    @Test("ES ↔ EN with everything cached: Whisper for my Spanish and for their English; never Kokoro")
    func wantedForSpanishEnglish() {
        let harness = Harness(source: "es", target: "en", probe: cachedAll)
        #expect(harness.preloader().wantedModels() == [.whisper])
    }

    @Test("EN → ES: Parakeet for my English, Whisper for their Spanish")
    func wantedForEnglishSpanish() {
        let harness = Harness(source: "en", target: "es", probe: cachedAll)
        #expect(harness.preloader().wantedModels() == [.parakeet, .whisper])
    }

    @Test("nothing on disk → nothing to preload (never downloads)")
    func nothingCached() async {
        let harness = Harness(source: "en", target: "es", probe: .none)
        let preloader = harness.preloader()
        await preloader.preload()
        #expect(harness.log.entries.isEmpty)
    }

    @Test("the voice clone is preloaded when it is my outgoing voice: on disk, enabled, with a profile (D-6)")
    func voiceCloneWhenOutgoingChoice() {
        let harness = Harness(source: "es", target: "en", probe: cachedAll)
        #expect(!harness.preloader().wantedModels().contains(.voiceClone), "Use my voice is off")
        harness.tts.setProfileStore(MockVoiceProfileStore())
        harness.tts.voiceCloningEnabled = true
        harness.tts.activeVoiceProfileId = UUID()
        #expect(harness.preloader().wantedModels() == [.whisper, .voiceClone])
    }

    @Test("a pair change unloads what the new pair no longer uses and loads the new picks")
    func pairChangeSwapsModels() async {
        let harness = Harness(source: "en", target: "es", probe: cachedAll)
        let preloader = harness.preloader()
        await preloader.preload()
        await harness.pair.setSourceLanguage(Locale.Language(identifier: "de"))
        await harness.pair.setTargetLanguage(Locale.Language(identifier: "es"))
        await preloader.preload()
        #expect(harness.log.entries.contains("unload parakeet"))
        #expect(harness.log.entries.filter { $0 == "load whisper" }.count == 1, "already loaded: not reloaded")
        #expect(preloader.loaded == [.whisper])
    }

    @Test("a session in progress blocks any change")
    func sessionBlocks() async {
        let harness = Harness(source: "en", target: "es", probe: cachedAll)
        let busy = harness.preloader(sessionActive: { true })
        await busy.preload()
        #expect(harness.log.entries.isEmpty)
    }

    @Test("the pair's choice drives the picks: Apple Speech chosen → Whisper unloaded (REQ-ST-61)")
    func pairChoiceDrivesPicks() async {
        let harness = Harness(source: "es", target: "en", probe: cachedAll)
        let preloader = harness.preloader()
        await preloader.preload()
        #expect(preloader.loaded == [.whisper])
        harness.stt.pairChoice = { PairModelChoice(stt: .appleSpeech) }
        await preloader.preload()
        #expect(harness.log.entries.last == "unload whisper")
        #expect(preloader.loaded.isEmpty)
    }

    @Test("a failed load is not recorded as loaded and is retried at the next preload (UI-B4)")
    func failedLoadIsRetried() async {
        let harness = Harness(source: "es", target: "en", probe: cachedAll)
        harness.log.failing.withLock { $0 = [.whisper] }
        let preloader = harness.preloader()
        await preloader.preload()
        #expect(preloader.loaded.isEmpty)
        harness.log.failing.withLock { $0 = [] }
        await preloader.preload()
        #expect(harness.log.entries == ["load whisper", "load whisper"])
        #expect(preloader.loaded == [.whisper])
    }

    @Test("a preload skipped during a call runs when the session-end trigger fires")
    func runsAfterSession() async {
        let harness = Harness(source: "es", target: "en", probe: cachedAll)
        var inSession = true
        var checks = 0
        let preloader = harness.preloader(sessionActive: { checks += 1; return inSession })
        let ended = PassthroughSubject<Void, Never>()
        preloader.start(triggers: [ended.eraseToAnyPublisher()])
        #expect(await waitUntil { checks >= 1 })
        #expect(harness.log.entries.isEmpty)
        inSession = false
        ended.send()
        #expect(await waitUntil { preloader.loaded == [.whisper] })
    }

    @Test("every trigger re-runs the preloader, debounced (REQ-ST-61)")
    func triggersRerun() async {
        let harness = Harness(source: "es", target: "en", probe: cachedAll)
        let preloader = harness.preloader()
        let trigger = PassthroughSubject<Void, Never>()
        preloader.start(triggers: [trigger.eraseToAnyPublisher()])
        #expect(await waitUntil { preloader.loaded == [.whisper] })
        harness.stt.pairChoice = { PairModelChoice(stt: .appleSpeech) }
        trigger.send()
        trigger.send()
        #expect(await waitUntil { preloader.loaded.isEmpty })
        #expect(harness.log.entries.filter { $0 == "unload whisper" }.count == 1)
    }

    @Test("turning \"Use my voice\" on loads a voice clone already on disk (preloadTriggers)")
    func useMyVoiceTriggerLoadsClone() async {
        let harness = Harness(source: "es", target: "en", probe: cachedAll)
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let models = ModelServices(choices: PairModelChoices(defaults: defaults),
                                   cloud: CloudPolicy(defaults: defaults, edgeConsentGiven: { false },
                                                      grantEdgeConsent: {}),
                                   downloads: ModelDownloads(probe: cachedAll, managers: DownloadManagers(
                                       download: { _ in }, cancel: { _ in })),
                                   stt: harness.stt, tts: harness.tts, languagePairManager: harness.pair)
        harness.tts.setProfileStore(MockVoiceProfileStore())
        harness.tts.activeVoiceProfileId = UUID()
        let preloader = harness.preloader()
        preloader.start(triggers: models.preloadTriggers(tts: harness.tts))
        #expect(await waitUntil { preloader.loaded == [.whisper] })
        harness.tts.enableVoiceCloning()
        #expect(await waitUntil { preloader.loaded == [.whisper, .voiceClone] })
        #expect(harness.log.entries.filter { $0 == "load voiceClone" }.count == 1)
    }
}

// MARK: - Load-only paths (P20: the preloader never triggers a download)

@Suite("Load-only model paths (M9 UI core D-6)")
struct ModelLoadOnlyTests {

    @Test("Parakeet: loadCached uses the cache-only factory, never the downloading one")
    func parakeetLoadCached() async throws {
        let downloads = CallCounter()
        let manager = ParakeetModelManager(managerFactory: { _ in downloads.increment(); return MockAsrTranscriber() },
                                           cachedFactory: { _ in MockAsrTranscriber() })
        try await manager.loadCached()
        #expect(await manager.modelState == .ready)
        #expect(downloads.value == 0)
    }

    @Test("Parakeet: a missing or unusable cache throws and is not repaired")
    func parakeetNotCached() async {
        let downloads = CallCounter()
        let manager = ParakeetModelManager(managerFactory: { _ in downloads.increment(); return MockAsrTranscriber() },
                                           cachedFactory: { _ in throw ModelCacheError.notCached })
        await #expect(throws: ModelCacheError.notCached) { try await manager.loadCached() }
        #expect(downloads.value == 0)
    }

    @Test("Whisper: loadCached uses the disk-only pipe, never the downloading one")
    func whisperLoadCached() async {
        let downloads = CallCounter()
        let manager = WhisperModelManager(pipeFactory: { _ in downloads.increment(); throw ModelCacheError.notCached },
                                          cachedPipeFactory: { _ in throw ModelCacheError.notCached })
        await #expect(throws: ModelCacheError.notCached) { try await manager.loadCached() }
        #expect(downloads.value == 0)
    }

    @Test("voice clone: loadCached loads only what is on disk")
    func voiceCloneLoadCached() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let loads = CallCounter()
        let manager = QwenCloneModelManager(config: QwenCloneConfiguration(modelRepo: "owner/model"),
                                            modelLoader: { _ in loads.increment(); return MockQwenCloneInferrer() })
        await #expect(throws: ModelCacheError.notCached) { try await manager.loadCached(home: home) }
        #expect(loads.value == 0)

        let folder = ModelCache.mlxAudioDirectory(repo: "owner/model", home: home)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("model.safetensors"))
        try await manager.loadCached(home: home)
        #expect(loads.value == 1)
    }
}
