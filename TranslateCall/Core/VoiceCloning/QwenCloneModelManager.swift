import Foundation
import MLXAudioTTS
import OSLog

nonisolated(unsafe) private let logger = Logger(
    subsystem: "com.spbarber.TranslateCall",
    category: "QwenCloneModelManager"
)

// MARK: - QwenCloneModelManager

/// Actor singleton managing the Qwen3-TTS model lifecycle.
///
/// Mirrors `KokoroModelManager` pattern:
/// - State machine: .idle → .downloading → .loading → .ready / .failed
/// - Concurrent callers to `ensureReady()` share a single in-flight Task (coalescing)
/// - `modelLoader` is injectable for unit tests (no real model download needed)
actor QwenCloneModelManager {

    // MARK: - State machine

    enum ModelState: Sendable {
        case idle
        case downloading
        case loading
        case ready
        case failed(String)
    }

    // MARK: - Singleton

    static let shared = QwenCloneModelManager()

    // MARK: - Internal state

    private(set) var state: ModelState = .idle
    private var loadTask: Task<Void, Error>?
    private var inferrer: QwenCloneClient?

    // Nonisolated copy for synchronous factory access (QwenCloneClient is Sendable)
    nonisolated(unsafe) private(set) var cachedInferrer: QwenCloneClient?

    private let stateContinuation: AsyncStream<ModelState>.Continuation
    nonisolated let stateStream: AsyncStream<ModelState>

    // MARK: - Factory

    typealias ModelLoader = @Sendable (String) async throws -> QwenCloneClient

    // Default loader: downloads and loads model via TTS.loadModel(), wraps in QwenCloneClient
    nonisolated(unsafe) static let defaultLoader: ModelLoader = { modelRepo in
        let model = try await TTS.loadModel(modelRepo: modelRepo)
        return QwenCloneClient(model: model)
    }

    private let modelLoader: ModelLoader
    private let config: QwenCloneConfiguration

    // MARK: - Init

    init(
        config: QwenCloneConfiguration = .default,
        modelLoader: @escaping ModelLoader = QwenCloneModelManager.defaultLoader
    ) {
        self.config = config
        self.modelLoader = modelLoader
        var cont: AsyncStream<ModelState>.Continuation!
        stateStream = AsyncStream { cont = $0 }
        stateContinuation = cont
    }

    // MARK: - Public API

    /// Loads the model if not already ready. Concurrent callers share one in-flight task.
    func ensureReady() async throws {
        switch state {
        case .ready:
            return
        case .downloading, .loading:
            if let task = loadTask {
                try await task.value
                return
            }
            try await startSetup()
        case .idle, .failed:
            try await startSetup()
        }
    }

    /// Returns the client when the model is ready.
    func getInferrer() throws -> QwenCloneClient {
        guard case .ready = state, let inferrer else {
            throw QwenCloneError.modelNotReady
        }
        return inferrer
    }

    /// Nonisolated sync accessor for the factory closure in TTSEngineSelector.
    /// Returns the cached inferrer if model is ready, nil otherwise.
    nonisolated func getInferrerSync() throws -> QwenCloneClient {
        guard let client = cachedInferrer else {
            throw QwenCloneError.modelNotReady
        }
        return client
    }

    /// Unloads the model and releases resources.
    func unload() {
        loadTask?.cancel()
        loadTask = nil
        inferrer = nil
        cachedInferrer = nil
        transition(to: .idle)
    }

    /// Checks whether the HuggingFace model cache directory exists.
    func isModelCached() -> Bool {
        let repoPath = config.modelRepo.replacingOccurrences(of: "/", with: "--")
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
            .appendingPathComponent("models--\(repoPath)")
        return FileManager.default.fileExists(atPath: cacheDir.path)
    }

    // MARK: - Private

    private func startSetup() async throws {
        transition(to: .downloading)
        let repo = config.modelRepo
        let loader = modelLoader

        let task = Task<Void, Error> {
            let client = try await loader(repo)
            self.inferrer = client
            self.cachedInferrer = client
            self.transition(to: .ready)
        }
        loadTask = task
        do {
            try await task.value
        } catch {
            // If unload() was called (state already .idle), don't override with .failed
            if case .idle = state {
                logger.debug("Download cancelled by unload — staying idle")
            } else {
                transition(to: .failed(error.localizedDescription))
            }
            throw error
        }
    }

    private func transition(to newState: ModelState) {
        state = newState
        stateContinuation.yield(newState)
        logger.debug("QwenCloneModelManager → \(String(describing: newState))")
    }
}
