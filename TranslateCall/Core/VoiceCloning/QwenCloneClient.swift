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
/// access through `MLXInferenceGate` (`QwenCloneModelManager.gatedInferrer()`).
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
        let params = generateParameters()

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

    func synthesizeStream(
        text: String,
        referenceAudio: [Float],
        referenceTranscript: String,
        language: String
    ) -> AsyncThrowingStream<QwenStreamEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: QwenStreamEvent.self)
        let relay = Task {
            do {
                let events = model.generateStream(
                    text: text,
                    voice: nil,
                    refAudio: MLXArray(referenceAudio),
                    refText: referenceTranscript,
                    language: language,
                    generationParameters: generateParameters(),
                    streamingInterval: config.streamingInterval
                )
                for try await event in events {
                    try Task.checkCancellation()
                    switch event {
                    case .audio(let chunk):
                        let samples = chunk.asArray(Float.self)
                        if !samples.isEmpty { continuation.yield(.audio(samples)) }
                    case .info(let info):
                        continuation.yield(.info(tokens: info.generationTokenCount,
                                                 tokensPerSecond: info.tokensPerSecond))
                    case .token:
                        break
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in relay.cancel() }
        return stream
    }

    private func generateParameters() -> GenerateParameters {
        GenerateParameters(
            maxTokens: config.maxTokens,
            temperature: config.temperature,
            topP: config.topP,
            repetitionPenalty: config.repetitionPenalty
        )
    }
}
