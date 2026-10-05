import AVFoundation

// MARK: - UtteranceSynthesizer

/// Text → PCM for one engine (F8.5.2 REQ-T-01/02). A synthesizer owns no audio engine or player
/// node: `TTSPlaybackService` schedules what it yields.
///
/// The stream yields one utterance's buffers in playback order, finishes when the utterance is
/// complete and throws on failure or timeout. When the consumer stops iterating, the stream's
/// `onTermination` cancels the producing work (for MLX: abandons it, see `MLXInferenceGate`).
nonisolated protocol UtteranceSynthesizer: Sendable {
    var engine: TTSEngine { get }
    func canSpeak(_ locale: Locale) -> Bool
    /// Longest text the engine speaks without cutting it; the playback service never coalesces past it
    /// (F8.5.3 REQ-Q-02). A single longer sentence is still handed over whole.
    var maxTextLength: Int { get }
    func synthesize(text: String, locale: Locale) -> AsyncThrowingStream<AVAudioPCMBuffer, Error>
    /// Releases long-lived resources (Edge closes its socket). Called by `TTSPlaybackService.deactivate()`.
    func shutdown() async
}

extension UtteranceSynthesizer {
    nonisolated func shutdown() async {}
    nonisolated var maxTextLength: Int { Int.max }
}

// MARK: - Events

/// Why an utterance was not heard in full (REQ-T-18).
nonisolated enum TTSSkipReason: Sendable, Equatable {
    case noVoice
    case primaryFailed(String)
    case interrupted
    case timeout
    case outputUnavailable
}

/// What `TTSPlaybackService.events` reports (REQ-T-18).
nonisolated enum TTSEvent: Sendable, Equatable {
    /// The queue reached `TTSPlaybackLimits.backlogNoticeThreshold` pending sentences (F8.5.3 REQ-Q-03).
    /// Nothing was dropped: the pending sentences are coalesced to catch up.
    case backlog(pending: Int)
    case utteranceSkipped(TTSSkipReason)
    // swiftlint:disable:next identifier_name
    case fellBack(from: TTSEngine, to: TTSEngine)   // labels fixed by REQ-T-18
}

// MARK: - Helpers shared by the synthesizers

/// The stream every synthesizer returns.
nonisolated enum UtteranceStream {
    /// Bounded like every stream in Core/TTS (REQ-T-50), but never reached in practice: the consumer
    /// schedules each buffer at once, and AVSpeech's burst (~86 buffers per second of speech, rendered
    /// faster than real time) stays far below this for any sentence (> 90 s of speech).
    static let bufferLimit = 8_192

    static func make() -> (
        stream: AsyncThrowingStream<AVAudioPCMBuffer, Error>,
        continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation
    ) {
        AsyncThrowingStream.makeStream(
            of: AVAudioPCMBuffer.self, throwing: Error.self, bufferingPolicy: .bufferingNewest(bufferLimit)
        )
    }
}

/// Builds the buffers Kokoro, Qwen and the Edge decoder hand to the playback service.
nonisolated enum PCMBufferFactory {
    /// Mono Float32 buffer holding `samples` at `sampleRate`; nil when `samples` is empty.
    static func mono(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        return buffer
    }
}

/// Text limits of the on-device engines (REQ-T-04).
nonisolated enum UtteranceText {
    /// Cuts `text` to at most `limit` characters at the last word boundary (Kokoro: 500,
    /// Qwen: `QwenCloneConfiguration.textTruncationLimit`). A text with no space is cut hard.
    static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let prefix = String(text.prefix(limit))
        let words = prefix.components(separatedBy: " ").dropLast()
        return words.isEmpty ? prefix : words.joined(separator: " ")
    }
}
