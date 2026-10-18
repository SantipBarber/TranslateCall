import Combine
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "ModelPreloader")

/// A model the preloader can load ahead of Start. Kokoro is not one: FluidAudio has no load path that
/// cannot download (its lexicon and voice files are fetched on demand), so it loads at Start (P20).
nonisolated enum PreloadModel: Hashable, Sendable {
    case parakeet, whisper, voiceClone
}

/// Loads and unloads one model; `load` returns true when the model is loaded. `live` uses the shared
/// managers' load-only paths, which throw instead of downloading (D-6, P20).
nonisolated struct ModelLoaders: Sendable {
    var load: @Sendable (PreloadModel) async -> Bool
    var unload: @Sendable (PreloadModel) async -> Void

    static let live = ModelLoaders(
        load: { model in
            do {
                switch model {
                case .parakeet: try await ParakeetModelManager.shared.loadCached()
                case .whisper: try await WhisperModelManager.shared.loadCached()
                case .voiceClone: try await QwenCloneModelManager.shared.loadCached()
                }
                return true
            } catch {
                logger.info("Preload of \(String(describing: model)) skipped: \(error.localizedDescription)")
                return false
            }
        },
        unload: { model in
            switch model {
            case .parakeet: await ParakeetModelManager.shared.unload()
            case .whisper: await WhisperModelManager.shared.unloadModel()
            case .voiceClone: break   // owned by "Use my voice": disableVoiceCloning() unloads it
            }
        }
    )
}

// MARK: - ModelPreloader

/// Preloads the cached models resolved for the current pair (its choice, else the catalog), at launch,
/// on every pair change and on every trigger `start(triggers:)` is given (a choice, the cloud policy, a
/// finished download, "Use my voice", its profile, the end of a session), so Start is fast (M9 UI core
/// D-6, REQ-UI-21a, design §3.3; M9 UI settings REQ-ST-61). Never downloads, never runs during a session;
/// a load that fails is retried at the next run (UI-B4). The voice clone is preloaded when it is the
/// outgoing choice; the catalog never picks Kokoro then, so one MLX TTS model at a time holds (NF-04).
/// `AppContainer` does not start it in the test host.
@MainActor
final class ModelPreloader {
    private let stt: STTEngineSelector
    private let tts: TTSEngineSelector
    private let languagePairManager: LanguagePairManager
    private let loaders: ModelLoaders
    private let isSessionActive: () -> Bool
    private(set) var loaded: Set<PreloadModel> = []
    private var pending: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(stt: STTEngineSelector, tts: TTSEngineSelector, languagePairManager: LanguagePairManager,
         loaders: ModelLoaders = .live, isSessionActive: @escaping () -> Bool) {
        self.stt = stt
        self.tts = tts
        self.languagePairManager = languagePairManager
        self.loaders = loaders
        self.isSessionActive = isSessionActive
    }

    /// Preloads now, then after every language change and every `triggers` event, debounced 300 ms so a
    /// burst of changes runs one preload (REQ-ST-61).
    func start(triggers: [AnyPublisher<Void, Never>] = []) {
        let pairChanges = languagePairManager.$sourceLanguage.combineLatest(languagePairManager.$targetLanguage)
            .removeDuplicates { $0 == $1 }
            .map { _ in () }
            .eraseToAnyPublisher()
        Publishers.MergeMany([pairChanges] + triggers)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.schedule() }
            .store(in: &cancellables)
    }

    /// The models the next session would load, given the pair, its choice and what is on disk.
    func wantedModels() -> Set<PreloadModel> {
        let source = Locale(identifier: languagePairManager.sourceLanguage.minimalIdentifier)
        let target = Locale(identifier: languagePairManager.targetLanguage.minimalIdentifier)
        let sttPicks = [stt.resolvedEngine(for: source, direction: .outgoing),
                        stt.resolvedEngine(for: target, direction: .incoming)]
        // My voice, spoken in their language.
        let outgoingVoice = tts.resolvedEngine(for: target, direction: .outgoing)
        var wanted: Set<PreloadModel> = []
        if sttPicks.contains(.parakeet) { wanted.insert(.parakeet) }
        if sttPicks.contains(.whisper) { wanted.insert(.whisper) }
        if outgoingVoice == .voiceClone { wanted.insert(.voiceClone) }
        return wanted
    }

    /// Loads what the pair needs and unloads what it no longer needs; a no-op during a session. Only a
    /// model that did load is recorded, so a failed one is tried again next time (UI-B4).
    func preload() async {
        guard !isSessionActive() else { return }
        let wanted = wantedModels()
        for model in loaded.subtracting(wanted) {
            await loaders.unload(model)
            loaded.remove(model)
        }
        for model in wanted.subtracting(loaded) {
            let didLoad = await loaders.load(model)
            if didLoad { loaded.insert(model) }
        }
    }

    private func schedule() {
        let previous = pending
        pending = Task { [weak self] in
            await previous?.value   // one preload at a time, in order
            await self?.preload()
        }
    }
}
