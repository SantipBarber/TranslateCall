import AVFoundation
import Foundation
import OSLog
import Speech

// nonisolated(unsafe): top-level let is @MainActor under SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor;
// Logger is immutable and thread-safe, so unsafe access is fine here.
nonisolated(unsafe) private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "AppleSpeechService")

// MARK: - AppleSpeechService

actor AppleSpeechService: SpeechRecognizerService {

    // MARK: - SpeechRecognizerService conformance

    nonisolated let transcriptionStream: AsyncStream<TranscriptionResult>
    // nonisolated(unsafe): locale is a value type written only from actor context (setLocale),
    // read nonisolated to satisfy protocol without requiring await at call site.
    nonisolated(unsafe) private(set) var locale: Locale

    // MARK: - Private state

    private let config: STTConfiguration
    private var continuation: AsyncStream<TranscriptionResult>.Continuation?
    private var processingTask: Task<Void, Never>?
    private var activeRecognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?

    // MARK: - Init

    init(locale: Locale, config: STTConfiguration = .default) {
        self.locale = locale
        self.config = config
        var cont: AsyncStream<TranscriptionResult>.Continuation?
        transcriptionStream = AsyncStream { cont = $0 }
        continuation = cont
        // Recognizer created lazily in activate() after permission check
    }

    // MARK: - SpeechRecognizerService

    func activate(stream: AsyncStream<SpeechSegment>) async throws {
        guard processingTask == nil else { return }

        // 1. Request authorization (callback API — bridge to async)
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard status == .authorized else {
            throw STTError.permissionDenied
        }

        // 2. Create recognizer for locale
        let rec = SFSpeechRecognizer(locale: locale)
        guard let rec, rec.isAvailable else {
            throw STTError.recognizerUnavailable(locale)
        }
        recognizer = rec

        // 3. Spawn processing loop
        processingTask = Task { [weak self] in
            guard let self else { return }
            await self.runProcessingLoop(stream: stream)
        }
    }

    func deactivate() async {
        processingTask?.cancel()
        processingTask = nil
        activeRecognitionTask?.cancel()
        activeRecognitionTask = nil
    }

    func setLocale(_ newLocale: Locale) async {
        guard newLocale != locale else { return }
        activeRecognitionTask?.cancel()
        activeRecognitionTask = nil
        locale = newLocale
        recognizer = SFSpeechRecognizer(locale: newLocale)
    }

    // MARK: - Private

    private func runProcessingLoop(stream: AsyncStream<SpeechSegment>) async {
        for await segment in stream {
            guard !Task.isCancelled else { break }
            if let result = await transcribeSegment(segment) {
                continuation?.yield(result)
            }
        }
    }

    private func transcribeSegment(_ segment: SpeechSegment) async -> TranscriptionResult? {
        guard let recognizer else { return nil }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition && config.preferOnDevice {
            request.requiresOnDeviceRecognition = true
        }
        request.append(segment.audio)
        request.endAudio()

        // Extract only Sendable values (String + [Float]) inside callback to avoid data race
        // on non-Sendable SFSpeechRecognitionResult across actor boundary.
        typealias STTPartial = (text: String, confidences: [Float])
        typealias STTContinuation = CheckedContinuation<STTPartial, Error>
        do {
            let partial = try await withCheckedThrowingContinuation { (cont: STTContinuation) in
                activeRecognitionTask = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        cont.resume(throwing: error)
                        return
                    }
                    guard let result, result.isFinal else { return }
                    let transcription = result.bestTranscription
                    cont.resume(returning: (
                        text: transcription.formattedString,
                        confidences: transcription.segments.map(\.confidence)
                    ))
                }
            }

            activeRecognitionTask = nil
            let confidence = partial.confidences.isEmpty ? 0 :
                partial.confidences.reduce(0, +) / Float(partial.confidences.count)
            guard confidence >= config.minimumConfidence else {
                logger.debug("Discarding low-confidence result: \(confidence)")
                return nil
            }

            let duration = Double(segment.audio.frameLength) / segment.audio.format.sampleRate
            return TranscriptionResult(
                text: partial.text,
                confidence: confidence,
                locale: locale,
                capturedAt: segment.capturedAt,
                audioDuration: duration
            )
        } catch {
            activeRecognitionTask = nil
            logger.error("Recognition failed: \(error.localizedDescription)")
            return nil
        }
    }

}
