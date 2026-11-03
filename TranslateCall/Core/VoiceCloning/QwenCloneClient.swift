import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS

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
    private let references = ReferenceAudioCache()

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
        let refAudio = references.array(for: referenceAudio)
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

    /// Relays mlx-audio's stream, and always drains it to its end (qwen-streaming design §3/§4).
    ///
    /// Invariant: this stream ends only when mlx-audio's stream has ended, i.e. when the model is done.
    /// mlx-audio's generation task is never cancelled (Qwen3TTS `generateStream`), so ending early would let
    /// `MLXInferenceGate`'s pump see "model done", release the gate and start a second MLX inference over a
    /// running one: the T6 process crash. So the relay is not cancelled with its consumer and never checks
    /// for cancellation; once the consumer has gone it stops converting and yielding, and keeps draining.
    func synthesizeStream(
        text: String,
        referenceAudio: [Float],
        referenceTranscript: String,
        language: String
    ) -> AsyncThrowingStream<QwenStreamEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: QwenStreamEvent.self)
        // Unstructured and never cancelled: it does not inherit the caller's cancellation either.
        Task {
            do {
                let events = model.generateStream(
                    text: text,
                    voice: nil,
                    refAudio: references.array(for: referenceAudio),
                    refText: referenceTranscript,
                    language: language,
                    generationParameters: generateParameters(),
                    streamingInterval: config.streamingInterval
                )
                try await Self.drain(events, into: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return stream
    }

    /// Iterates `events` to their end; relays them while `continuation`'s consumer listens.
    private static func drain(
        _ events: AsyncThrowingStream<AudioGeneration, Error>,
        into continuation: AsyncThrowingStream<QwenStreamEvent, Error>.Continuation
    ) async throws {
        var listening = true
        for try await event in events {
            guard listening else { continue }         // nobody listens: keep draining to the model's end
            let relayed: QwenStreamEvent?
            switch event {
            case .audio(let chunk):
                let samples = chunk.asArray(Float.self)
                relayed = samples.isEmpty ? nil : .audio(samples)
            case .info(let info):
                // mlx-audio sends .info before the last audio chunk: it is never the end of the stream.
                relayed = .info(tokens: info.generationTokenCount, tokensPerSecond: info.tokensPerSecond)
            case .token, .progress:
                relayed = nil
            }
            if let relayed, case .terminated = continuation.yield(relayed) { listening = false }
        }
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
