import AVFoundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "QwenUtteranceSynthesizer")

// MARK: - QwenUtteranceSynthesizer

/// Qwen3-TTS voice clone (F8.5.2 REQ-T-02/04): the active profile's reference audio and transcript plus
/// the text (cut at `config.textTruncationLimit`) give one buffer at the inferrer's sample rate.
/// Production injects `QwenCloneModelManager.gatedInferrer()`, so inference goes through the gate.
nonisolated final class QwenUtteranceSynthesizer: UtteranceSynthesizer {
    let engine: TTSEngine = .voiceClone
    private let activeProfileId: UUID
    private let profileStore: any VoiceProfileStoring
    private let inferrer: any QwenCloneInferring
    private let config: QwenCloneConfiguration

    init(
        activeProfileId: UUID,
        profileStore: any VoiceProfileStoring,
        inferrer: any QwenCloneInferring,
        config: QwenCloneConfiguration = .default
    ) {
        self.activeProfileId = activeProfileId
        self.profileStore = profileStore
        self.inferrer = inferrer
        self.config = config
    }

    func canSpeak(_ locale: Locale) -> Bool {
        QwenCloneConfiguration.supportsLocale(locale)
    }

    func synthesize(text: String, locale: Locale) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let (stream, continuation) = UtteranceStream.make()
        let input = UtteranceText.truncated(text, limit: config.textTruncationLimit)
        if input.count < text.count {
            logger.warning("Voice clone text truncated from \(text.count) to \(input.count) characters")
        }
        let language = QwenCloneConfiguration.language(for: locale) ?? "english"
        let producer = Task { [activeProfileId, profileStore, inferrer] in
            do {
                let profile = try await profileStore.load(id: activeProfileId)
                guard let samples = profile.samples, let transcript = profile.transcript else {
                    throw VoiceProfileError.payloadMissing
                }
                let audio = try await inferrer.synthesize(
                    text: input, referenceAudio: samples, referenceTranscript: transcript, language: language
                )
                try Task.checkCancellation()
                guard !audio.isEmpty,
                      let buffer = PCMBufferFactory.mono(audio, sampleRate: Double(inferrer.sampleRate)) else {
                    throw QwenCloneError.emptyOutput
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
