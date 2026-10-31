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

    /// Streaming synthesis: audio chunks as the model produces them, then one `.info`. Synchronous so the
    /// caller can hand the stream on; cancelling the consumer ends the model's work (the gate drains).
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
