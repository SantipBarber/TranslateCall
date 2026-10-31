import AVFoundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "QwenUtteranceSynthesizer")

// MARK: - QwenUtteranceSynthesizer

/// Qwen3-TTS voice clone (F8.5.2 REQ-T-02/04, qwen-streaming REQ-QS-01/04/22): the active profile's
/// reference audio and transcript plus the text (cut at `config.textTruncationLimit`) stream as one buffer
/// per model chunk at the inferrer's sample rate, so playback starts with the first chunk.
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

    var maxTextLength: Int { config.textTruncationLimit }

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
            var stats = SentenceStats(start: ContinuousClock.now)
            do {
                let profile = try await profileStore.load(id: activeProfileId)
                guard let samples = profile.samples, let transcript = profile.transcript else {
                    throw VoiceProfileError.payloadMissing
                }
                let events = inferrer.synthesizeStream(
                    text: input, referenceAudio: samples, referenceTranscript: transcript, language: language
                )
                try await Self.relay(events, sampleRate: inferrer.sampleRate, to: continuation, stats: &stats)
                stats.log(SentenceOutcome(ending: nil, cancelled: Task.isCancelled))
                try Task.checkCancellation()
                guard stats.hasAudio else { throw QwenCloneError.emptyOutput }
                continuation.finish()
            } catch {
                stats.log(SentenceOutcome(ending: error, cancelled: Task.isCancelled))
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in producer.cancel() }
        return stream
    }

    /// Yields one buffer per non-empty `.audio` chunk and records the sentence's timings.
    private static func relay(
        _ events: AsyncThrowingStream<QwenStreamEvent, Error>,
        sampleRate: Int,
        to continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation,
        stats: inout SentenceStats
    ) async throws {
        for try await event in events {
            try Task.checkCancellation()
            switch event {
            case .audio(let samples):
                guard let buffer = PCMBufferFactory.mono(samples, sampleRate: Double(sampleRate)) else { continue }
                stats.chunk(seconds: Double(samples.count) / Double(sampleRate))
                continuation.yield(buffer)
            case .info(_, let tokensPerSecond):
                stats.tokensPerSecond = tokensPerSecond
            }
        }
    }
}

// MARK: - SentenceOutcome

/// How a voice-clone sentence ended, for its log line (G1 M2): a stopped sentence also ends its relay
/// loop without an error, so the cancellation is read from the task as well.
nonisolated enum SentenceOutcome: String, Sendable {
    case finished, cancelled, error

    init(ending error: Error?, cancelled: Bool) {
        if cancelled || error is CancellationError {
            self = .cancelled
        } else {
            self = error == nil ? .finished : .error
        }
    }
}

// MARK: - SentenceStats

/// One sentence's streaming timings, logged once at its end when it produced audio (P14: numbers only).
nonisolated private struct SentenceStats {
    let start: ContinuousClock.Instant
    var tracker = StreamGapTracker()
    var audioSeconds: Double = 0
    var tokensPerSecond: Double = 0
    private var logged = false

    init(start: ContinuousClock.Instant) {
        self.start = start
    }

    var hasAudio: Bool { tracker.firstChunkAt != nil }

    mutating func chunk(seconds: Double) {
        tracker.chunk(arrivedAt: ContinuousClock.now - start, seconds: seconds)
        audioSeconds += seconds
    }

    mutating func log(_ outcome: SentenceOutcome) {
        guard !logged, let firstChunk = tracker.firstChunkAt else { return }
        logged = true
        let firstChunkMs = Int((firstChunk.secondsValue * 1_000).rounded())
        let totalMs = Int(((ContinuousClock.now - start).secondsValue * 1_000).rounded())
        let gapCount = tracker.gapCount
        let gapMs = Int((tracker.gapSeconds * 1_000).rounded())
        let audio = String(format: "%.2f", audioSeconds)
        let rate = String(format: "%.1f", tokensPerSecond)
        let ending = outcome.rawValue
        logger.info("""
            Voice clone sentence: outcome=\(ending, privacy: .public) firstChunkMs=\(firstChunkMs, privacy: .public) \
            totalMs=\(totalMs, privacy: .public) audioSeconds=\(audio, privacy: .public) \
            tokensPerSecond=\(rate, privacy: .public) gapCount=\(gapCount, privacy: .public) \
            gapMs=\(gapMs, privacy: .public)
            """)
    }
}
