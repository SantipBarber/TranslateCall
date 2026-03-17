import FluidAudioEspeak
import Foundation
import OSLog

nonisolated private let kokoroModelLogger = Logger(
    subsystem: "com.spbarber.TranslateCall",
    category: "KokoroModelManager"
)

// MARK: - KokoroModelManager

/// Actor singleton managing the Kokoro TTS model lifecycle.
///
/// Mirrors `ParakeetModelManager` from F6.1:
/// - State machine: .idle → .loading → .ready / .failed
/// - Concurrent callers to `ensureReady()` share a single in-flight Task (coalescing)
/// - `managerFactory` is injectable for unit tests (no real model download needed)
actor KokoroModelManager {

    // MARK: - State machine

    enum ModelState: Sendable {
        case idle
        case loading
        case ready(any KokoroTtsManaging)
        case failed(String)
    }

    // MARK: - Singleton

    static let shared = KokoroModelManager()

    // MARK: - Internal state

    private(set) var state: ModelState = .idle
    private var loadTask: Task<any KokoroTtsManaging, Error>?

    private let stateContinuation: AsyncStream<ModelState>.Continuation
    nonisolated let stateStream: AsyncStream<ModelState>

    // MARK: - Factory

    typealias ManagerFactory = @Sendable (KokoroConfiguration) async throws -> any KokoroTtsManaging

    nonisolated static let defaultFactory: ManagerFactory = { config in
        let voice = config.voiceIdentifier.isEmpty ? nil : config.voiceIdentifier
        let manager = KokoroTtsManager(defaultVoice: voice ?? "af_heart")
        try await manager.initialize()
        return manager
    }

    private let managerFactory: ManagerFactory

    // MARK: - Init

    init(managerFactory: @escaping ManagerFactory = KokoroModelManager.defaultFactory) {
        self.managerFactory = managerFactory
        var cont: AsyncStream<ModelState>.Continuation?
        stateStream = AsyncStream { cont = $0 }
        // swiftlint:disable:next force_unwrapping
        stateContinuation = cont!
    }

    // MARK: - Public API

    /// Returns a ready manager, loading it if necessary.
    /// Concurrent callers share one in-flight load task.
    func ensureReady(config: KokoroConfiguration = .default) async throws -> any KokoroTtsManaging {
        switch state {
        case .ready(let mgr):
            return mgr
        case .loading:
            guard let task = loadTask else { return try await startLoading(config: config) }
            return try await task.value
        case .idle, .failed:
            return try await startLoading(config: config)
        }
    }

    func unload() {
        loadTask?.cancel()
        loadTask = nil
        transition(to: .idle)
    }

    func redownload(config: KokoroConfiguration = .default) async throws -> any KokoroTtsManaging {
        unload()
        return try await startLoading(config: config)
    }

    // MARK: - Private

    private func startLoading(config: KokoroConfiguration) async throws -> any KokoroTtsManaging {
        transition(to: .loading)
        let task = Task<any KokoroTtsManaging, Error> {
            try await managerFactory(config)
        }
        loadTask = task
        do {
            let mgr = try await task.value
            transition(to: .ready(mgr))
            return mgr
        } catch {
            transition(to: .failed(error.localizedDescription))
            throw error
        }
    }

    private func transition(to newState: ModelState) {
        state = newState
        stateContinuation.yield(newState)
        kokoroModelLogger.debug("KokoroModelManager → \(String(describing: newState))")
    }
}
