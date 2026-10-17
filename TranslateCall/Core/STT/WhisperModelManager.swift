import Foundation
import OSLog
@preconcurrency import WhisperKit

private nonisolated let logger = Logger(
    subsystem: "com.spbarber.TranslateCall",
    category: "WhisperModelManager"
)

// MARK: - WhisperModelManager

/// Singleton actor managing WhisperKit model download, caching, and loading.
/// Uses task coalescing: concurrent `ensureReady()` calls share a single load.
actor WhisperModelManager {
    static let shared = WhisperModelManager()

    // MARK: - Observable state

    private(set) var isReady: Bool = false
    private(set) var isDownloading: Bool = false
    private(set) var downloadProgress: Double = 0
    private(set) var currentModelSize: WhisperModelSize = .base
    private(set) var loadError: Error?

    // MARK: - Private

    private var pipe: WhisperKit?
    private var loadTask: Task<WhisperKit, Error>?
    private let pipeFactory: Factory
    private let cachedPipeFactory: Factory

    /// Creates a loaded WhisperKit for a model size.
    typealias Factory = @Sendable (WhisperModelSize) async throws -> WhisperKit

    // MARK: - Init

    init(
        pipeFactory: @escaping Factory = { size in
            let config = WhisperKitConfig()
            config.model = size.whisperKitName
            config.verbose = false
            return try await WhisperKit(config)
        },
        cachedPipeFactory: @escaping Factory = WhisperModelManager.cacheOnlyPipe
    ) {
        self.pipeFactory = pipeFactory
        self.cachedPipeFactory = cachedPipeFactory
    }

    // MARK: - Public API

    /// Returns a ready WhisperKit instance, downloading the model if needed.
    /// Concurrent calls share a single download/load operation (task coalescing).
    func ensureReady(
        config: WhisperConfiguration = .default
    ) async throws -> WhisperKit {
        try await load(config.modelSize, using: pipeFactory)
    }

    /// Loads the model if not ready. Does not return the pipe (avoids Sendable issues).
    func loadIfNeeded(config: WhisperConfiguration = .default) async throws {
        _ = try await ensureReady(config: config)
    }

    /// Loads the model from disk only; throws `ModelCacheError.notCached` instead of downloading
    /// (M9 UI core D-6).
    func loadCached(config: WhisperConfiguration = .default) async throws {
        _ = try await load(config.modelSize, using: cachedPipeFactory)
    }

    /// Releases the model from memory.
    func unloadModel() {
        pipe = nil
        loadTask?.cancel()
        loadTask = nil
        isReady = false
        isDownloading = false
        downloadProgress = 0
        loadError = nil
        logger.info("Whisper model unloaded")
    }

    /// WhisperKit with downloads off, on the folder its default download wrote. The tokenizer is
    /// checked too: WhisperKit would fetch a missing one.
    nonisolated static let cacheOnlyPipe: Factory = { size in
        let folder = ModelCache.whisperDirectory(for: size)
        guard ModelCache.allExist(ModelCache.whisperRequired, in: folder),
              ModelCache.hasWhisperTokenizer(for: size) else { throw ModelCacheError.notCached }
        let config = WhisperKitConfig()
        config.modelFolder = folder.path
        config.download = false
        config.verbose = false
        return try await WhisperKit(config)
    }

    // MARK: - Private

    private func load(_ size: WhisperModelSize, using factory: @escaping Factory) async throws -> WhisperKit {
        // Return cached pipe if size matches
        if let pipe, currentModelSize == size {
            return pipe
        }

        // Coalesce: if a load is in progress, piggyback on it
        if let loadTask {
            return try await loadTask.value
        }

        let task = Task<WhisperKit, Error> {
            isDownloading = true
            currentModelSize = size
            loadError = nil
            logger.info("Loading Whisper model: \(size.rawValue)")
            do {
                let kit = try await factory(size)
                self.pipe = kit
                self.isReady = true
                self.isDownloading = false
                logger.info("Whisper model ready: \(size.rawValue)")
                return kit
            } catch {
                self.loadError = error
                self.isDownloading = false
                self.loadTask = nil
                logger.error("Whisper model load failed: \(error.localizedDescription)")
                throw error
            }
        }
        loadTask = task
        let result = try await task.value
        loadTask = nil
        return result
    }
}
