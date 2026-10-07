import AVFoundation
import Foundation
import OSLog
import Synchronization

nonisolated private let parakeetLogger = Logger(
    subsystem: "com.spbarber.TranslateCall",
    category: "ParakeetSpeechService"
)

// MARK: - ParakeetSpeechService

/// `SpeechRecognizerService` implementation backed by FluidAudio Parakeet TDT v3.
///
/// **English only**: `activate(stream:)` throws `STTError.recognizerUnavailable(locale)`
/// for any non-English locale. `STTEngineSelector` catches this and routes the pipeline
/// to `AppleSpeechService` transparently.
///
/// **Segment-based**: VAD segments are transcribed in serial by `AsrManager.transcribe([Float])`.
/// The transcriber is lazily loaded on the first `activate()` call and retained across
/// subsequent `deactivate()/activate()` cycles to avoid redundant model loading.
actor ParakeetSpeechService: SpeechRecognizerService {

    // MARK: - SpeechRecognizerService

    nonisolated let transcriptionStream: AsyncStream<TranscriptionResult>

    /// Read without `await` (protocol requirement); written by `setLocale` on the actor. The lock makes
    /// the cross-isolation read race-free (F8.5.4 REQ-TR-60).
    private let localeState: Mutex<Locale>
    nonisolated var locale: Locale { localeState.withLock { $0 } }

    // MARK: - Private state

    private let config: STTConfiguration
    private let parakeetConfig: ParakeetConfiguration
    private var continuation: AsyncStream<TranscriptionResult>.Continuation?
    private var processingTask: Task<Void, Never>?

    /// Lazily created on first `activate()`; retained across sessions.
    private var transcriber: (any AsrTranscriber)?

    /// Factory called once to obtain the `AsrTranscriber` (real or mock).
    ///
    /// Default: `ParakeetModelManager.shared.ensureReady()`.
    /// Tests inject a closure returning `MockAsrTranscriber` without loading CoreML.
    private let transcriberFactory: @Sendable () async throws -> any AsrTranscriber

    // MARK: - Init

    init(
        locale: Locale,
        config: STTConfiguration = .default,
        parakeetConfig: ParakeetConfiguration = .default,
        transcriberFactory: @escaping @Sendable () async throws -> any AsrTranscriber = {
            try await ParakeetModelManager.shared.ensureReady()
        }
    ) {
        self.localeState = Mutex(locale)
        self.config = config
        self.parakeetConfig = parakeetConfig
        self.transcriberFactory = transcriberFactory
        var cont: AsyncStream<TranscriptionResult>.Continuation?
        transcriptionStream = AsyncStream { cont = $0 }
        continuation = cont
    }

    // MARK: - SpeechRecognizerService

    func activate(stream: AsyncStream<SpeechSegment>) async throws {
        guard processingTask == nil else { return }

        // Parakeet only speaks English.
        let currentLocale = locale
        guard currentLocale.isEnglish else {
            parakeetLogger.warning("Parakeet cannot handle locale \(currentLocale.identifier); use AppleSpeechService")
            throw STTError.recognizerUnavailable(currentLocale)
        }

        // Load model on first use; reuse across sessions.
        if transcriber == nil {
            transcriber = try await transcriberFactory()
            parakeetLogger.info("Parakeet transcriber loaded")
        }

        processingTask = Task { [weak self] in
            guard let self else { return }
            await self.runProcessingLoop(stream: stream)
        }

        parakeetLogger.info("ParakeetSpeechService activated for \(self.locale.identifier)")
    }

    func deactivate() async {
        processingTask?.cancel()
        processingTask = nil
        parakeetLogger.info("ParakeetSpeechService deactivated")
    }

    func setLocale(_ newLocale: Locale) async {
        guard newLocale != locale else { return }
        localeState.withLock { $0 = newLocale }
        // Non-English locales are rejected on the next activate(); no immediate action needed.
    }

    // MARK: - Private — processing loop

    private func runProcessingLoop(stream: AsyncStream<SpeechSegment>) async {
        for await segment in stream {
            guard !Task.isCancelled else { break }
            if let result = await transcribeSegment(segment) {
                continuation?.yield(result)
            }
        }
    }

    private func transcribeSegment(_ segment: SpeechSegment) async -> TranscriptionResult? {
        guard let transcriber else {
            parakeetLogger.error("transcribeSegment called before model was loaded")
            return nil
        }

        let startDate = Date()
        let inputSamples = prepareInputSamples(from: segment)
        guard let inputSamples else { return nil }

        do {
            let output = try await transcriber.transcribeAudio(inputSamples)
            let text = output.text
            let confidence = output.confidence
            let audioDuration = output.duration
            let latencyMs = Int(Date().timeIntervalSince(startDate) * 1000)
            let segmentDurationMs = Int(
                Double(segment.audio.frameLength) / segment.audio.format.sampleRate * 1000
            )

            // Record A/B metrics regardless of confidence threshold.
            await STTMetricsCollector.shared.record(
                STTMetrics(
                    engine: .parakeet,
                    segmentDurationMs: segmentDurationMs,
                    transcriptionLatencyMs: latencyMs,
                    confidence: confidence,
                    textLength: text.count,
                    timestamp: .now
                )
            )

            guard confidence >= config.minimumConfidence else {
                parakeetLogger.debug(
                    "Discarding low-confidence Parakeet result: \(String(format: "%.2f", confidence))"
                )
                return nil
            }

            return TranscriptionResult(
                text: text,
                confidence: confidence,
                locale: locale,
                capturedAt: segment.capturedAt,
                audioDuration: audioDuration
            )
        } catch {
            parakeetLogger.error("Parakeet transcription error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Extracts and validates input samples from a speech segment, truncating if needed.
    private func prepareInputSamples(from segment: SpeechSegment) -> [Float]? {
        let samples = segment.audio.toFloatSamples()
        guard !samples.isEmpty else {
            parakeetLogger.warning("Empty audio buffer in speech segment — skipping")
            return nil
        }

        // Parakeet max capacity: 15 s × 16 000 samples/s = 240 000 samples.
        let maxSamples = 240_000
        if samples.count > maxSamples {
            parakeetLogger.warning(
                "Segment too long (\(samples.count) samples); truncating to \(maxSamples)"
            )
            return Array(samples.prefix(maxSamples))
        }
        return samples
    }
}
