import AVFoundation
import Foundation
import OSLog
@preconcurrency import WhisperKit

private nonisolated let logger = Logger(
    subsystem: "com.spbarber.TranslateCall",
    category: "WhisperSpeechService"
)

// WhisperKit's TranscriptionResult clashes with ours.
// Our type is qualified as `TranslateCall.TranscriptionResult`.
// WhisperKit's `TranscriptionResult` is used unqualified for params/locals.

// MARK: - WhisperSpeechService

actor WhisperSpeechService: SpeechRecognizerService {

    // MARK: - Protocol conformance

    nonisolated let transcriptionStream: AsyncStream<TranslateCall.TranscriptionResult>
    nonisolated(unsafe) private(set) var locale: Locale

    // MARK: - Private state

    private var continuation: AsyncStream<TranslateCall.TranscriptionResult>.Continuation?
    private var processingTask: Task<Void, Never>?
    private var pipe: WhisperKit?
    private let config: STTConfiguration
    private let whisperConfig: WhisperConfiguration
    private let pipeFactory: @Sendable () async throws -> WhisperKit

    private let maxSamples = 480_000

    // MARK: - Init

    init(
        locale: Locale,
        config: STTConfiguration = .default,
        whisperConfig: WhisperConfiguration = .default,
        pipeFactory: @Sendable @escaping () async throws -> WhisperKit = {
            try await WhisperModelManager.shared.ensureReady()
        }
    ) {
        self.locale = locale
        self.config = config
        self.whisperConfig = whisperConfig
        self.pipeFactory = pipeFactory

        var cont: AsyncStream<TranslateCall.TranscriptionResult>.Continuation?
        self.transcriptionStream = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    // MARK: - SpeechRecognizerService

    func activate(stream: AsyncStream<SpeechSegment>) async throws {
        if pipe == nil {
            pipe = try await pipeFactory()
        }
        processingTask?.cancel()
        processingTask = Task { [weak self] in
            for await segment in stream {
                guard !Task.isCancelled else { break }
                await self?.transcribeSegment(segment)
            }
        }
    }

    func deactivate() async {
        processingTask?.cancel()
        processingTask = nil
    }

    func setLocale(_ newLocale: Locale) async {
        locale = newLocale
    }

    // MARK: - Transcription

    private func transcribeSegment(_ segment: SpeechSegment) async {
        guard let pipe else { return }
        let startDate = Date()

        guard let channelData = segment.audio.floatChannelData else { return }
        let count = min(Int(segment.audio.frameLength), maxSamples)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
        guard !samples.isEmpty else { return }

        let langCode = WhisperLanguages.whisperCode(for: locale)
            ?? whisperConfig.language
        var options = DecodingOptions()
        options.language = langCode
        options.verbose = false
        options.withoutTimestamps = true

        let results = await pipe.transcribe(
            audioArrays: [samples], decodeOptions: options
        )
        guard let first = results.first,
              let wkResult = first?.first else { return }

        await emitResult(
            text: wkResult.text,
            segments: wkResult.segments,
            segment: segment,
            startDate: startDate,
            sampleCount: count
        )
    }

    private func emitResult(
        text rawText: String,
        segments: [TranscriptionSegment],
        segment: SpeechSegment,
        startDate: Date,
        sampleCount: Int
    ) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let confidence = computeConfidence(from: segments)
        let audioDuration = TimeInterval(sampleCount) / 16_000.0
        let latencyMs = Int(Date().timeIntervalSince(startDate) * 1000)

        await STTMetricsCollector.shared.record(STTMetrics(
            engine: .whisper,
            segmentDurationMs: Int(audioDuration * 1000),
            transcriptionLatencyMs: latencyMs,
            confidence: confidence,
            textLength: text.count,
            timestamp: Date()
        ))

        guard confidence >= config.minimumConfidence else {
            logger.debug("Whisper: low confidence \(confidence), skipping")
            return
        }

        continuation?.yield(TranslateCall.TranscriptionResult(
            text: text,
            confidence: confidence,
            locale: locale,
            capturedAt: segment.capturedAt,
            audioDuration: audioDuration
        ))
    }

    private func computeConfidence(
        from segments: [TranscriptionSegment]
    ) -> Float {
        guard !segments.isEmpty else { return 0 }
        let meanLogProb = segments.reduce(Float(0)) { $0 + $1.avgLogprob }
            / Float(segments.count)
        return min(1.0, max(0.0, exp(meanLogProb)))
    }
}
