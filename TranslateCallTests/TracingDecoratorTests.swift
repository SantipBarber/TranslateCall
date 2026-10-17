import AVFoundation
import Foundation
import Testing
@testable import TranslateCall

/// M9 design §2.2: each decorator passes its stage through unchanged and reports it to the tracer.
@Suite("Tracing decorators") @MainActor
struct TracingDecoratorTests {
    let sink = CollectingTraceSink()
    var tracer: PipelineTracer { PipelineTracer(direction: .outgoing, sink: sink, trailingSilence: .milliseconds(600)) }

    @Test func vadForwardsSegmentsAndStampsThem() async throws {
        let inner = MockVADService(engine: .silero)
        let vad = TracingVADService(wrapping: inner, tracer: tracer)
        #expect(vad.engine == .silero)
        try await vad.activate(stream: AsyncStream { $0.finish() })
        let segment = SpeechSegment(audio: makePCMBuffer(frames: 16_000), capturedAt: Date())
        let received = Task { () -> Date? in for await got in vad.speechSegments { return got.capturedAt }; return nil }
        await inner.injectSpeechSegment(segment)
        #expect(await received.value == segment.capturedAt)
        #expect(sink.stages(of: 0) == [.speechStart, .vadEnd])
        #expect(sink.event(0, .vadEnd)?.detail["segmentAudioMs"] == "1000")
        await vad.deactivate()
        #expect(await inner.deactivateCalled)
    }

    @Test func sttForwardsResultsAndStampsThem() async throws {
        let tracer = tracer
        let date = Date()
        tracer.segmentClosed(capturedAt: date, audioSeconds: 1)
        let inner = MockSpeechRecognizerService()
        let stt = TracingSTTService(wrapping: inner, tracer: tracer)
        try await stt.activate(stream: AsyncStream { $0.finish() })
        let received = Task { () -> String? in for await got in stt.transcriptionStream { return got.text }; return nil }
        await inner.injectTranscription(TranscriptionResult(text: "hola", confidence: 0.9, locale: stt.locale,
                                                            capturedAt: date, audioDuration: 1))
        #expect(await received.value == "hola")
        #expect(sink.event(0, .sttFinal)?.detail["engine"] == "MockSpeechRecognizerService")
        await stt.deactivate()
    }

    @Test func translationPassesThroughAndStampsSuccessAndFailure() async throws {
        let tracer = tracer
        let date = Date()
        for (offset, text) in ["a", "b"].enumerated() {
            tracer.segmentClosed(capturedAt: date + Double(offset), audioSeconds: 1)
            tracer.transcribed(capturedAt: date + Double(offset), text: text, engine: "x", confidence: 1)
        }
        let inner = MockTranslationService()
        inner.errors = [TranslationError.timedOut]
        let service = TracingTranslationService(wrapping: inner, tracer: tracer)
        let (es, en) = (Locale.Language(identifier: "es"), Locale.Language(identifier: "en"))
        await #expect(throws: TranslationError.timedOut) { try await service.translate(text: "a", from: es, to: en) }
        #expect(try await service.translate(text: "b", from: es, to: en) == "TRANSLATED: b")
        #expect(sink.event(0, .dropped) != nil)
        #expect(sink.event(1, .translated)?.detail["text"] == "TRANSLATED: b")
        await service.warmUp(from: es, to: en)
        #expect(inner.warmUpCalls.count == 1)
    }

    /// The real playback service between the TTS decorators: first buffer and end, merged sentences.
    @Test func playbackServiceIsTracedEndToEnd() async throws {
        let tracer = tracer
        let date = Date()
        for (offset, text) in ["one", "two"].enumerated() {
            tracer.segmentClosed(capturedAt: date + Double(offset), audioSeconds: 1)
            tracer.transcribed(capturedAt: date + Double(offset), text: text, engine: "x", confidence: 1)
            tracer.translated(source: text, result: text.uppercased())
        }
        let primary = FakeSynthesizer()
        let output = FakeOutput(autoComplete: true)
        let playback = TTSPlaybackService(primary: tracer.tracing(primary), output: tracer.tracing(output))
        let tts = TracingSynthesisService(wrapping: playback, tracer: tracer)
        let english = Locale(identifier: "en")
        await tts.speak(text: "ONE", locale: english)
        await tts.speak(text: "TWO", locale: english)
        #expect(await waitUntil { tracer.openSeqs.isEmpty })
        #expect(sink.stages(of: 0).suffix(2) == [.ttsFirstBuffer, .ttsEnd])
        #expect(sink.stages(of: 1).suffix(2) == [.ttsFirstBuffer, .ttsEnd])
        #expect(output.scheduledCount == primary.texts.count)
        await tts.deactivate()
    }
}
