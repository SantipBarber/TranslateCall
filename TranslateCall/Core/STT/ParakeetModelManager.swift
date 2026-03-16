import CoreML
import FluidAudio
import Foundation
import OSLog

nonisolated private let modelLogger = Logger(
    subsystem: "com.spbarber.TranslateCall",
    category: "ParakeetModelManager"
)

// MARK: - ParakeetModelManager

/// Singleton actor managing the FluidAudio Parakeet CoreML model lifecycle.
///
/// Responsibilities:
/// - Load from cache or download on first use.
/// - Coalesce concurrent `ensureReady()` callers so the model is only loaded once.
/// - Publish state changes via `stateStream` so the UI can show a download indicator.
/// - Release memory on demand via `unload()`.
actor ParakeetModelManager {

    // MARK: - Singleton

    /// Shared production instance. Tests create isolated instances with injected factories.
    static let shared = ParakeetModelManager()

    // MARK: - State

    enum ModelState: Sendable, Equatable {
        /// No model has been requested yet.
        case idle
        /// Model is being loaded from cache or downloaded.
        case loading
        /// Model is loaded and ready for transcription.
        case ready
        /// Load or download failed. `message` contains the localized error description.
        case failed(String)
    }

    /// Current state. Starts as `.idle`; transitions are published on `stateStream`.
    private(set) var modelState: ModelState = .idle

    /// Async stream of state transitions for UI observation.
    ///
    /// `nonisolated let` — safe to read from any context without `await` because
    /// it is fully initialized before any async work begins.
    nonisolated let stateStream: AsyncStream<ModelState>
    private var stateStreamContinuation: AsyncStream<ModelState>.Continuation?

    // MARK: - Internal

    /// Coalesces concurrent `ensureReady()` callers.
    private var loadTask: Task<any AsrTranscriber, Error>?

    /// Retained after first load; cleared on `unload()`.
    private var asrManager: (any AsrTranscriber)?

    /// Injected factory — creates a ready `AsrTranscriber` from a `ParakeetConfiguration`.
    ///
    /// Default implementation tries the cache first, falls back to download.
    /// Tests inject a factory that returns a mock immediately.
    private let managerFactory: @Sendable (ParakeetConfiguration) async throws -> any AsrTranscriber

    // MARK: - Init

    init(
        managerFactory: @escaping @Sendable (ParakeetConfiguration) async throws
            -> any AsrTranscriber = ParakeetModelManager.defaultFactory
    ) {
        self.managerFactory = managerFactory
        var cont: AsyncStream<ModelState>.Continuation?
        stateStream = AsyncStream { cont = $0 }
        stateStreamContinuation = cont
    }

    // MARK: - Public API

    /// Returns a ready `AsrTranscriber`, loading or downloading the model if needed.
    ///
    /// Concurrent callers share the same in-flight `loadTask` — the model is
    /// downloaded and initialized exactly once per app session.
    func ensureReady(config: ParakeetConfiguration = .default) async throws -> any AsrTranscriber {
        // Fast path: model already loaded.
        if let existing = asrManager {
            return existing
        }

        // Coalesce: if a load is already in progress, await it.
        if let inflight = loadTask {
            return try await inflight.value
        }

        // Start a new load task.
        let task = Task { [self] in
            try await self.performLoad(config: config)
        }
        loadTask = task

        do {
            let mgr = try await task.value
            loadTask = nil
            return mgr
        } catch {
            loadTask = nil
            throw error
        }
    }

    /// Discards the cached model files and re-downloads from scratch.
    ///
    /// Called from Settings when the user explicitly requests a fresh download.
    func redownload(config: ParakeetConfiguration = .default) async throws {
        loadTask?.cancel()
        loadTask = nil
        asrManager?.cleanup()
        asrManager = nil
        updateState(.idle)
        _ = try await ensureReady(config: config)
    }

    /// Releases the loaded model from memory without deleting the disk cache.
    ///
    /// Called when Parakeet is deselected as the engine or the app is going into background.
    func unload() {
        loadTask?.cancel()
        loadTask = nil
        asrManager?.cleanup()
        asrManager = nil
        updateState(.idle)
        modelLogger.info("Parakeet model unloaded from memory")
    }

    // MARK: - Private

    private func performLoad(config: ParakeetConfiguration) async throws -> any AsrTranscriber {
        updateState(.loading)
        modelLogger.info("Loading Parakeet model (version: \(String(describing: config.modelVersion)))…")
        do {
            let mgr = try await managerFactory(config)
            asrManager = mgr
            updateState(.ready)
            modelLogger.info("Parakeet model ready")
            return mgr
        } catch {
            let msg = error.localizedDescription
            updateState(.failed(msg))
            modelLogger.error("Parakeet model load failed: \(msg)")
            throw error
        }
    }

    private func updateState(_ state: ModelState) {
        modelState = state
        stateStreamContinuation?.yield(state)
    }

    // MARK: - Default factory

    /// Tries to load from cache; falls back to download.
    nonisolated static let defaultFactory: @Sendable (ParakeetConfiguration) async throws
        -> any AsrTranscriber = { config in
        let mlConfig = MLModelConfiguration()
        mlConfig.computeUnits = config.preferANE ? .all : .cpuAndGPU

        let models: AsrModels
        do {
            models = try await AsrModels.loadFromCache(
                configuration: mlConfig,
                version: config.modelVersion
            )
            modelLogger.debug("Loaded Parakeet model from cache")
        } catch {
            modelLogger.info("Cache miss (\(error.localizedDescription)); downloading…")
            models = try await AsrModels.downloadAndLoad(
                configuration: mlConfig,
                version: config.modelVersion
            )
            modelLogger.debug("Downloaded Parakeet model")
        }

        let mgr = AsrManager()
        try await mgr.initialize(models: models)
        return mgr
    }
}
