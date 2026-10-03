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

    var sampleRate: Int { get }
}
