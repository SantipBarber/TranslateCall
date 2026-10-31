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

    nonisolated private static let defaultLoader: ModelLoader = { modelRepo in
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

    /// A streamed Qwen3-TTS inference through the gate (REQ-QS-02/03). Fails fast, as a stream that throws,
    /// when the model is not loaded or a previous sentence nobody listens to still holds the gate. Once the
    /// gate admits it, the model is checked again (REQ-QS-08): an unload that slipped in while it queued ends
    /// it with `.modelNotReady`, and the released client is never used.
    func synthesizeStream(
        text: String,
        referenceAudio: [Float],
        referenceTranscript: String,
        language: String
    ) async -> AsyncThrowingStream<QwenStreamEvent, Error> {
        guard case .ready = state, inferrer != nil else { return Self.failingStream(.modelNotReady) }
        if await gate.isHeldByAbandonedStream {
            logger.info("Voice clone sentence fails fast: a stream nobody listens to still holds the gate")
            return Self.failingStream(.gateBusyAbandoned)
        }
        return gate.runStream(
            firstElement: .seconds(config.firstChunkTimeoutSeconds),
            isFirst: { if case .audio = $0 { true } else { false } },
            admit: { [self] in try await admittedInferrer() },
            work: { inferrer in
                inferrer.synthesizeStream(
                    text: text,
                    referenceAudio: referenceAudio,
                    referenceTranscript: referenceTranscript,
                    language: language
                )
            }
        )
    }

    /// One short inference with the active voice, so the session's first real sentence is not the model's
    /// cold first run (REQ-QS-31: measured 1.5–2× slower to first chunk). It goes through the gate like any
    /// sentence, so a real one that comes meanwhile waits for it, or goes to the fallback under the usual
    /// rules (REQ-QS-03/07a). Drained to its end, output and errors ignored; a no-op when the model is not
    /// loaded. Cancelling the caller stops listening only: the gate still drains the model (REQ-QS-06).
    func warmUp(profileStore: any VoiceProfileStoring, activeProfileId: UUID, locale: Locale) async {
        guard case .ready = state else { return }
        let start = ContinuousClock.now
        var failure: Error?
        do {
            let profile = try await profileStore.load(id: activeProfileId)
            guard let samples = profile.samples, let transcript = profile.transcript else {
                throw VoiceProfileError.payloadMissing
            }
            let events = await synthesizeStream(
                text: Self.warmUpText(for: locale),
                referenceAudio: samples,
                referenceTranscript: transcript,
                language: QwenCloneConfiguration.language(for: locale) ?? "english"
            )
            for try await _ in events {}
        } catch {
            failure = error
        }
        let outcome = SentenceOutcome(ending: failure, cancelled: Task.isCancelled).rawValue
        let durationMs = Int(((ContinuousClock.now - start).secondsValue * 1_000).rounded())
        logger.info("""
            Voice clone warm-up: outcome=\(outcome, privacy: .public) durationMs=\(durationMs, privacy: .public)
            """)
    }

    /// "Hola." for a Spanish target, "Hello." otherwise: the shortest sentence that runs the whole model.
    nonisolated static func warmUpText(for locale: Locale) -> String {
        locale.language.languageCode == .spanish ? "Hola." : "Hello."
    }

    /// The loaded client, read with the gate held; `.modelNotReady` when an unload came first.
    private func admittedInferrer() throws -> any QwenCloneInferring {
        guard case .ready = state, let inferrer else {
            logger.info("Voice clone sentence ends: the model was unloaded while it waited for the gate")
            throw QwenCloneError.modelNotReady
        }
        return inferrer
    }

    nonisolated private static func failingStream(
        _ error: QwenCloneError
    ) -> AsyncThrowingStream<QwenStreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
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

    /// The model is downloaded: mlx-audio's working copy holds `config.json` and non-empty weights
    /// (M9 UI core D-6). The `models--…` hub folder alone does not prove that.
    nonisolated func isModelCached(home: URL = ModelCache.homeDirectory) -> Bool {
        ModelCache.hasMLXWeights(in: ModelCache.mlxAudioDirectory(repo: config.modelRepo, home: home))
    }

    /// Loads the model only when it is on disk; throws `ModelCacheError.notCached` otherwise and never
    /// downloads (M9 UI core D-6): mlx-audio uses a folder that passes `isModelCached` as it is.
    func loadCached(home: URL = ModelCache.homeDirectory) async throws {
        guard isModelCached(home: home) else { throw ModelCacheError.notCached }
        try await ensureReady()
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

    /// The manager's stream, relayed (P13): the manager call is async, this one is not.
    func synthesizeStream(
        text: String,
        referenceAudio: [Float],
        referenceTranscript: String,
        language: String
    ) -> AsyncThrowingStream<QwenStreamEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: QwenStreamEvent.self)
        let manager = manager
        let relay = Task {
            let inner = await manager.synthesizeStream(
                text: text,
                referenceAudio: referenceAudio,
                referenceTranscript: referenceTranscript,
                language: language
            )
            do {
                for try await event in inner { continuation.yield(event) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in relay.cancel() }
        return stream
    }
}
