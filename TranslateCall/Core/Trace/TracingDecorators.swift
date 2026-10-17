import AVFoundation
import Foundation

// Pass-through decorators that report each stage to a `PipelineTracer` (M9 design §2.2).
// They never change what flows through; with no tracer wired the app does not create them.

// MARK: - VAD

actor TracingVADService: VADService {
    nonisolated let speechSegments: AsyncStream<SpeechSegment>
    nonisolated let vadStateEvents: AsyncStream<Bool>
    nonisolated let engine: VADEngine
    private let inner: any VADService
    private let tracer: PipelineTracer
    private let continuation: AsyncStream<SpeechSegment>.Continuation
    private var forward: Task<Void, Never>?

    init(wrapping inner: any VADService, tracer: PipelineTracer) {
        self.inner = inner
        self.tracer = tracer
        vadStateEvents = inner.vadStateEvents
        engine = inner.engine
        (speechSegments, continuation) = AsyncStream.makeStream(of: SpeechSegment.self)
    }

    func activate(stream: AsyncStream<AVAudioPCMBuffer>) async throws {
        try await inner.activate(stream: stream)
        let (segments, continuation, tracer) = (inner.speechSegments, continuation, tracer)
        forward = Task {
            for await segment in segments {
                tracer.segmentClosed(capturedAt: segment.capturedAt,
                                     audioSeconds: Double(segment.audio.frameLength) / segment.audio.format.sampleRate)
                continuation.yield(segment)
            }
            continuation.finish()
        }
    }

    func deactivate() async {
        await inner.deactivate()
        forward?.cancel()
        forward = nil
        continuation.finish()
    }
}

// MARK: - STT

actor TracingSTTService: SpeechRecognizerService {
    nonisolated let transcriptionStream: AsyncStream<TranscriptionResult>
    nonisolated var locale: Locale { inner.locale }
    private nonisolated let inner: any SpeechRecognizerService
    private let tracer: PipelineTracer
    private let continuation: AsyncStream<TranscriptionResult>.Continuation
    private var forward: Task<Void, Never>?

    init(wrapping inner: any SpeechRecognizerService, tracer: PipelineTracer) {
        self.inner = inner
        self.tracer = tracer
        (transcriptionStream, continuation) = AsyncStream.makeStream(of: TranscriptionResult.self)
    }

    func activate(stream: AsyncStream<SpeechSegment>) async throws {
        try await inner.activate(stream: stream)
        let (results, continuation, tracer) = (inner.transcriptionStream, continuation, tracer)
        let engine = String(describing: type(of: inner))
        forward = Task {
            for await result in results {
                tracer.transcribed(capturedAt: result.capturedAt, text: result.text, engine: engine,
                                   confidence: result.confidence)
                continuation.yield(result)
            }
            continuation.finish()
        }
    }

    func deactivate() async {
        await inner.deactivate()
        forward?.cancel()
        forward = nil
        continuation.finish()
    }

    func setLocale(_ locale: Locale) async { await inner.setLocale(locale) }
}

// MARK: - Translation

final class TracingTranslationService: TranslationService {
    private let inner: any TranslationService
    private let tracer: PipelineTracer

    init(wrapping inner: any TranslationService, tracer: PipelineTracer) {
        self.inner = inner
        self.tracer = tracer
    }

    var engineName: String { inner.engineName }

    func translate(text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        do {
            let result = try await inner.translate(text: text, from: source, to: target)
            tracer.translated(source: text, result: result)
            return result
        } catch {
            tracer.translationFailed(source: text, error: error)
            throw error
        }
    }

    /// The warm-up probe is not an utterance: untraced.
    func warmUp(from source: Locale.Language, to target: Locale.Language) async {
        await inner.warmUp(from: source, to: target)
    }

    func supports(source: Locale.Language, target: Locale.Language) async -> Bool {
        await inner.supports(source: source, target: target)
    }
}

// MARK: - TTS

actor TracingSynthesisService: SynthesisService {
    nonisolated let isSpeakingStream: AsyncStream<Bool>
    nonisolated let ttsEvents: AsyncStream<TTSEvent>?
    private let inner: any SynthesisService
    private let tracer: PipelineTracer

    init(wrapping inner: any SynthesisService, tracer: PipelineTracer) {
        self.inner = inner
        self.tracer = tracer
        isSpeakingStream = inner.isSpeakingStream
        ttsEvents = inner.ttsEvents
    }

    func speak(text: String, locale: Locale) async {
        tracer.speakRequested(text: text)
        await inner.speak(text: text, locale: locale)
    }

    func stopSpeaking() async { await inner.stopSpeaking() }
    func deactivate() async { await inner.deactivate() }
    func setAudioMonitor(_ monitor: TTSAudioMonitor?) async { await inner.setAudioMonitor(monitor) }
}

/// Marks where each synthesis attempt starts and ends; the text tells which utterances it carries.
nonisolated struct TracingUtteranceSynthesizer: UtteranceSynthesizer {
    let inner: any UtteranceSynthesizer
    let tracer: PipelineTracer

    var engine: TTSEngine { inner.engine }
    var maxTextLength: Int { inner.maxTextLength }
    func canSpeak(_ locale: Locale) -> Bool { inner.canSpeak(locale) }
    func shutdown() async { await inner.shutdown() }

    func synthesize(text: String, locale: Locale) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        tracer.synthesisStarted(text: text, engine: inner.engine.rawValue)
        let source = inner.synthesize(text: text, locale: locale)
        let (stream, continuation) = UtteranceStream.make()
        let tracer = tracer
        let forward = Task {
            do {
                for try await buffer in source { continuation.yield(buffer) }
                tracer.synthesisFinished()
                continuation.finish()
            } catch {
                tracer.synthesisFinished()
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in forward.cancel() }
        return stream
    }
}

/// Stamps each buffer as it is scheduled on the device (`ttsFirstBuffer`).
nonisolated final class TracingAudioOutput: AudioOutputting, Sendable {
    private let inner: any AudioOutputting
    private let tracer: PipelineTracer

    init(wrapping inner: any AudioOutputting, tracer: PipelineTracer) {
        self.inner = inner
        self.tracer = tracer
    }

    func schedule(_ buffer: AVAudioPCMBuffer) throws -> PlaybackHandle {
        let handle = try inner.schedule(buffer)
        tracer.bufferScheduled()
        return handle
    }

    func stop() { inner.stop() }
    func shutdown() { inner.shutdown() }
}
