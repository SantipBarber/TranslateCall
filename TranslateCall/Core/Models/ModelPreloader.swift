import Combine
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "ModelPreloader")

/// A model the preloader can load ahead of Start. Kokoro is not one: FluidAudio has no load path that
/// cannot download (its lexicon and voice files are fetched on demand), so it loads at Start (P20).
nonisolated enum PreloadModel: Hashable, Sendable {
    case parakeet, whisper, voiceClone
}

/// Loads and unloads one model; `live` uses the shared managers' load-only paths, which throw
/// instead of downloading (D-6, P20).
nonisolated struct ModelLoaders: Sendable {
    var load: @Sendable (PreloadModel) async -> Void
    var unload: @Sendable (PreloadModel) async -> Void

    static let live = ModelLoaders(
        load: { model in
            do {
                switch model {
                case .parakeet: try await ParakeetModelManager.shared.loadCached()
                case .whisper: try await WhisperModelManager.shared.loadCached()
                case .voiceClone: try await QwenCloneModelManager.shared.loadCached()
                }
            } catch {
                logger.info("Preload of \(String(describing: model)) skipped: \(error.localizedDescription)")
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

/// Preloads the cached models the catalog picks for the current pair, at launch and on every
/// pair change, so Start is fast (M9 UI core D-6, REQ-UI-21a, design §3.3). Never downloads,
/// never runs during a session. The voice clone is preloaded when it is the outgoing choice; the
/// catalog never picks Kokoro then, so one MLX TTS model at a time holds (NF-04).
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

    /// Preloads now and after every language change.
    func start() {
        languagePairManager.$sourceLanguage.combineLatest(languagePairManager.$targetLanguage)
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.schedule() }
            .store(in: &cancellables)
    }

    /// The models the next session would load, given the pair and what is on disk.
    func wantedModels() -> Set<PreloadModel> {
        guard stt.isAutomatic else { return [] }
        let source = Locale(identifier: languagePairManager.sourceLanguage.minimalIdentifier)
        let target = Locale(identifier: languagePairManager.targetLanguage.minimalIdentifier)
        let sttAvailable = stt.availability
        let sttPicks = [
            ModelChoice.stt(for: source, direction: .outgoing, catalog: stt.catalog, availability: sttAvailable),
            ModelChoice.stt(for: target, direction: .incoming, catalog: stt.catalog, availability: sttAvailable)
        ]
        // My voice, spoken in their language.
        let outgoingVoice = ModelChoice.tts(for: target, direction: .outgoing, catalog: tts.catalog,
                                            availability: tts.availability)
        var wanted: Set<PreloadModel> = []
        if sttPicks.contains(.parakeet) { wanted.insert(.parakeet) }
        if sttPicks.contains(.whisper) { wanted.insert(.whisper) }
        if outgoingVoice == .voiceClone { wanted.insert(.voiceClone) }
        return wanted
    }

    /// Loads what the pair needs and unloads what it no longer needs; a no-op during a session and in
    /// manual mode, where the user's picks own the models and `loaded` is left as it is (R27).
    func preload() async {
        guard stt.isAutomatic, !isSessionActive() else { return }
        let wanted = wantedModels()
        for model in loaded.subtracting(wanted) { await loaders.unload(model) }
        for model in wanted.subtracting(loaded) { await loaders.load(model) }
        loaded = wanted
    }

    private func schedule() {
        let previous = pending
        pending = Task { [weak self] in
            await previous?.value   // one preload at a time, in order
            await self?.preload()
        }
    }
}
