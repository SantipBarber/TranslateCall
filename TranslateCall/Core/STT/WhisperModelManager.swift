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
    private let pipeFactory: @Sendable (WhisperModelSize) async throws -> WhisperKit

    // MARK: - Init

    init(
        pipeFactory: @Sendable @escaping (WhisperModelSize) async throws -> WhisperKit = { size in
            let config = WhisperKitConfig()
            config.model = size.whisperKitName
            config.verbose = false
            return try await WhisperKit(config)
        }
    ) {
        self.pipeFactory = pipeFactory
    }

    // MARK: - Public API

    /// Returns a ready WhisperKit instance, downloading the model if needed.
    /// Concurrent calls share a single download/load operation (task coalescing).
    func ensureReady(
        config: WhisperConfiguration = .default
    ) async throws -> WhisperKit {
        // Return cached pipe if size matches
        if let pipe, currentModelSize == config.modelSize {
            return pipe
        }

        // Coalesce: if a load is in progress, piggyback on it
        if let loadTask {
            return try await loadTask.value
        }

        let size = config.modelSize
        let task = Task<WhisperKit, Error> {
            isDownloading = true
            currentModelSize = size
            loadError = nil
            logger.info("Loading Whisper model: \(size.rawValue)")
            do {
                let kit = try await pipeFactory(size)
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
}
