import Foundation
import Synchronization
import Testing
@testable import TranslateCall

/// Records load/unload calls in order.
private final class LoaderLog: Sendable {
    private let calls = Mutex<[String]>([])
    var entries: [String] { calls.withLock { $0 } }
    var loaders: ModelLoaders {
        ModelLoaders(load: { model in self.calls.withLock { $0.append("load \(model)") } },
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
        stt = STTEngineSelector(defaults: defaults, appleSpeechFactory: { MockSpeechRecognizerService(locale: $0) },
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

    @Test("manual mode preloads nothing; a session in progress blocks any change")
    func manualAndSession() async {
        let harness = Harness(source: "en", target: "es", probe: cachedAll)
        harness.stt.setAutomatic(false)
        #expect(harness.preloader().wantedModels().isEmpty)

        harness.stt.setAutomatic(true)
        let busy = harness.preloader(sessionActive: { true })
        await busy.preload()
        #expect(harness.log.entries.isEmpty)
    }

    @Test("switching to manual keeps what automatic mode loaded: no unloads on a later preload (R27)")
    func manualKeepsLoadedModels() async {
        let harness = Harness(source: "en", target: "es", probe: cachedAll)
        let preloader = harness.preloader()
        await preloader.preload()
        #expect(preloader.loaded == [.parakeet, .whisper])

        harness.stt.setAutomatic(false)
        await harness.pair.setSourceLanguage(Locale.Language(identifier: "de"))
        await preloader.preload()
        #expect(!harness.log.entries.contains { $0.hasPrefix("unload") })
        #expect(preloader.loaded == [.parakeet, .whisper])
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
