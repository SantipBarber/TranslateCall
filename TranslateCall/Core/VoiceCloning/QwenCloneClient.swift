import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS
import MLXLMCommon

// MARK: - QwenCloneClient

/// Production implementation of `QwenCloneInferring` wrapping mlx-audio-swift.
///
/// Not an actor because `SpeechGenerationModel` existential is not `Sendable`
/// in Swift 6 strict concurrency, and calling `await model.generate()` from an
/// actor triggers "sending non-Sendable value" errors. Instead, this is a plain
/// class with `@unchecked Sendable`. Thread safety is guaranteed by the underlying
/// model (`Qwen3TTSModel` is `@unchecked Sendable`) and by the caller serializing
/// access through `QwenCloneSpeechService` (which is an actor).
nonisolated final class QwenCloneClient: QwenCloneInferring, @unchecked Sendable {

    private let model: any SpeechGenerationModel
    private let config: QwenCloneConfiguration

    let sampleRate: Int

    init(model: any SpeechGenerationModel, config: QwenCloneConfiguration = .default) {
        self.model = model
        self.config = config
        self.sampleRate = model.sampleRate
    }

    func synthesize(
        text: String,
        referenceAudio: [Float],
        referenceTranscript: String,
        language: String
    ) async throws -> [Float] {
        let refAudio = MLXArray(referenceAudio)

        let params = GenerateParameters(
            maxTokens: config.maxTokens,
            temperature: config.temperature,
            topP: config.topP,
            repetitionPenalty: config.repetitionPenalty
        )

        let output = try await model.generate(
            text: text,
            voice: nil,
            refAudio: refAudio,
            refText: referenceTranscript,
            language: language,
            generationParameters: params
        )

        return output.asArray(Float.self)
    }
}
