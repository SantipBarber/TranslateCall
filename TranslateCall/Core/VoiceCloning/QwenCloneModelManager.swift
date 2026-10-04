import Foundation
import MLXAudioTTS
import OSLog

nonisolated private let logger = Logger(
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
///
/// The loaded client is private: inference is only reachable through `synthesize`, which goes through
/// `MLXInferenceGate`, so no two MLX inferences ever overlap (F8.5.2 REQ-T-31, backlog T6).
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
    private var inferrer: (any QwenCloneInferring)?

    private let stateContinuation: AsyncStream<ModelState>.Continuation
    nonisolated let stateStream: AsyncStream<ModelState>

    // MARK: - Factory

    typealias ModelLoader = @Sendable (String) async throws -> any QwenCloneInferring

    nonisolated static let defaultLoader: ModelLoader = { modelRepo in
        let model = try await TTS.loadModel(modelRepo: modelRepo)
        return QwenCloneClient(model: model)
    }

    private let modelLoader: ModelLoader
    private let config: QwenCloneConfiguration
    private let gate: MLXInferenceGate

    // MARK: - Init

    init(
        config: QwenCloneConfiguration = .default,
        modelLoader: @escaping ModelLoader = QwenCloneModelManager.defaultLoader,
        gate: MLXInferenceGate = .shared
    ) {
        self.config = config
        self.modelLoader = modelLoader
        self.gate = gate
        (stateStream, stateContinuation) = AsyncStream.makeStream(
            of: ModelState.self, bufferingPolicy: .bufferingNewest(8)
        )
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

    /// One Qwen3-TTS inference, through the process-wide gate (REQ-T-30…32): waits at most 2 s for
    /// another inference, and gives up after `config.inferenceTimeoutSeconds` (the gate stays closed
    /// until MLX actually returns).
    func synthesize(
        text: String,
        referenceAudio: [Float],
        referenceTranscript: String,
        language: String
    ) async throws -> [Float] {
        guard case .ready = state, let inferrer else { throw QwenCloneError.modelNotReady }
        return try await gate.run(inference: .seconds(config.inferenceTimeoutSeconds)) {
            try await inferrer.synthesize(
                text: text,
                referenceAudio: referenceAudio,
                referenceTranscript: referenceTranscript,
                language: language
            )
        }
    }

    /// A `QwenCloneInferring` for `QwenUtteranceSynthesizer` and `VoicePreviewService` whose every
    /// call goes through `synthesize`, i.e. through the gate.
    nonisolated func gatedInferrer() -> any QwenCloneInferring {
        GatedQwenInferrer(manager: self, sampleRate: config.outputSampleRate)
    }

    /// Unloads the model. New inferences fail from the first line on; the client is released only
    /// once the gate is idle, never under a running MLX inference (design §6).
    func unload() async {
        loadTask?.cancel()
        loadTask = nil
        transition(to: .idle)
        await gate.waitUntilIdle()
        if case .idle = state { inferrer = nil }   // a reload during the wait keeps its new client
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

// MARK: - GatedQwenInferrer

/// `QwenCloneInferring` over `QwenCloneModelManager.synthesize` (and so over `MLXInferenceGate`).
nonisolated struct GatedQwenInferrer: QwenCloneInferring {
    let manager: QwenCloneModelManager
    let sampleRate: Int

    func synthesize(
        text: String,
        referenceAudio: [Float],
        referenceTranscript: String,
        language: String
    ) async throws -> [Float] {
        try await manager.synthesize(
            text: text,
            referenceAudio: referenceAudio,
            referenceTranscript: referenceTranscript,
            language: language
        )
    }
}
