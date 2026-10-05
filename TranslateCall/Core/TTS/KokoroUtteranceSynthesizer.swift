import AVFoundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "KokoroUtteranceSynthesizer")

// MARK: - KokoroUtteranceError

nonisolated enum KokoroUtteranceError: Error, Equatable, LocalizedError {
    /// The model returned no samples: never a silent success, so the playback service falls back.
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .emptyOutput: return "Kokoro synthesis produced no audio."
        }
    }
}

// MARK: - KokoroUtteranceSynthesizer

/// Kokoro (FluidAudio CoreML, English only) as an `UtteranceSynthesizer` (F8.5.2 REQ-T-02/04): the text,
/// cut at 500 characters on a word boundary, gives one 24 kHz mono buffer.
nonisolated final class KokoroUtteranceSynthesizer: UtteranceSynthesizer {
    static let truncationLimit = 500
    static let sampleRate: Double = 24_000

    let engine: TTSEngine = .kokoro
    private let configuration: KokoroConfiguration
    private let modelManager: KokoroModelManager

    init(configuration: KokoroConfiguration = .default, modelManager: KokoroModelManager = .shared) {
        self.configuration = configuration
        self.modelManager = modelManager
    }

    var maxTextLength: Int { Self.truncationLimit }

    func canSpeak(_ locale: Locale) -> Bool {
        locale.isEnglish
    }

    func synthesize(text: String, locale: Locale) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let (stream, continuation) = UtteranceStream.make()
        let input = UtteranceText.truncated(text, limit: Self.truncationLimit)
        if input.count < text.count {
            logger.warning("Kokoro text truncated from \(text.count) to \(input.count) characters")
        }
        let voice = configuration.voiceIdentifier.isEmpty ? nil : configuration.voiceIdentifier
        let producer = Task { [modelManager, configuration] in
            do {
                let manager = try await modelManager.ensureReady(config: configuration)
                try Task.checkCancellation()   // stopped while the model loaded: never synthesize (A9)
                let samples = try await manager.synthesizeSamples(text: input, voice: voice)
                try Task.checkCancellation()
                guard let buffer = PCMBufferFactory.mono(samples, sampleRate: Self.sampleRate) else {
                    throw KokoroUtteranceError.emptyOutput
                }
                continuation.yield(buffer)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in producer.cancel() }
        return stream
    }
}
