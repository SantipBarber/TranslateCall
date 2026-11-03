import Foundation

// MARK: - QwenCloneInferring

/// Abstracts Qwen3-TTS inference for testability.
///
/// Production: `QwenCloneClient` wraps mlx-audio-swift's `SpeechGenerationModel`.
/// Tests: `MockQwenCloneInferrer` (actor) returns stub samples.
///
/// Uses `Sendable` (not `Actor`) because the production implementation wraps a
/// non-Sendable existential (`any SpeechGenerationModel`) that cannot cross actor
/// isolation boundaries in Swift 6 strict concurrency. Actors can still conform.
nonisolated protocol QwenCloneInferring: Sendable {
    func synthesize(
        text: String,
        referenceAudio: [Float],
        referenceTranscript: String,
        language: String
    ) async throws -> [Float]

    /// Streaming synthesis: audio chunks as the model produces them, and one `.info` with the token stats.
    /// The `.info` is not the end: mlx-audio sends it before the last audio chunk (before the only one, for a
    /// short sentence); only the stream's own end means "done". Synchronous so the caller can hand it on.
    ///
    /// The stream ends only when the model's work has ended. Cancelling or dropping the consumer does not
    /// stop the model (mlx-audio's generation cannot be cancelled): the implementation keeps draining it
    /// unheard, so `MLXInferenceGate` stays closed until the model is really done (T6).
    func synthesizeStream(
        text: String,
        referenceAudio: [Float],
        referenceTranscript: String,
        language: String
    ) -> AsyncThrowingStream<QwenStreamEvent, Error>

    var sampleRate: Int { get }
}

// MARK: - QwenStreamEvent

/// What a streaming Qwen3-TTS synthesis reports.
nonisolated enum QwenStreamEvent: Sendable, Equatable {
    case audio([Float])
    case info(tokens: Int, tokensPerSecond: Double)
}
