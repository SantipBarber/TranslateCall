import AVFoundation
import Foundation
import Testing
@testable import TranslateCall

// MARK: - ParakeetSpeechServiceTests

/// Tests for `ParakeetSpeechService`.
///
/// All tests use `MockAsrTranscriber` via the `transcriberFactory` injection point —
/// no real CoreML model is loaded.
@Suite("ParakeetSpeechService", .serialized)
@MainActor
struct ParakeetSpeechServiceTests {

    // MARK: - Helpers

    /// A 16 kHz mono Float32 buffer with `frameCount` zero-filled samples.
    func makeBuffer(frameCount: Int = 16_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        // Fill with a small non-zero value so toFloatSamples() returns non-empty
        buffer.floatChannelData![0].initialize(repeating: 0.01, count: frameCount)
        return buffer
    }

    func makeSegment(frameCount: Int = 16_000) -> SpeechSegment {
        SpeechSegment(audio: makeBuffer(frameCount: frameCount), capturedAt: Date())
    }

    /// Creates a service backed by a fresh `MockAsrTranscriber`.
    func makeService(
        locale: Locale = Locale(identifier: "en-US"),
        config: STTConfiguration = .default,
        mock: MockAsrTranscriber
    ) -> ParakeetSpeechService {
        ParakeetSpeechService(
            locale: locale,
            config: config,
            transcriberFactory: { mock }
        )
    }

    /// Builds a single-element `AsyncStream<SpeechSegment>` that closes after emitting `segment`.
    func singleSegmentStream(_ segment: SpeechSegment) -> AsyncStream<SpeechSegment> {
        AsyncStream { cont in
            cont.yield(segment)
            cont.finish()
        }
    }

    // MARK: - Locale

    @Test("Initialises with given locale")
    func initialisesWithLocale() async {
        let mock = MockAsrTranscriber()
        let service = makeService(locale: Locale(identifier: "en-US"), mock: mock)
        #expect(service.locale == Locale(identifier: "en-US"))
    }

    @Test("setLocale updates locale for English")
    func setLocaleEnglishUpdates() async {
        let mock = MockAsrTranscriber()
        let service = makeService(mock: mock)
        await service.setLocale(Locale(identifier: "en-GB"))
        #expect(service.locale == Locale(identifier: "en-GB"))
    }

    @Test("setLocale stores non-English locale (rejection happens at activate)")
    func setLocaleNonEnglishStored() async {
        let mock = MockAsrTranscriber()
        let service = makeService(mock: mock)
        await service.setLocale(Locale(identifier: "fr-FR"))
        #expect(service.locale == Locale(identifier: "fr-FR"))
    }

    // MARK: - activate

    @Test("activate throws recognizerUnavailable for non-English locale")
    func activateThrowsForNonEnglish() async {
        let mock = MockAsrTranscriber()
        let service = makeService(locale: Locale(identifier: "fr-FR"), mock: mock)
        let stream = singleSegmentStream(makeSegment())

        do {
            try await service.activate(stream: stream)
            Issue.record("Expected throw for non-English locale")
        } catch STTError.recognizerUnavailable {
            // Expected
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test("activate succeeds for English locale")
    func activateSucceedsForEnglish() async throws {
        let mock = MockAsrTranscriber()
        let service = makeService(locale: Locale(identifier: "en-US"), mock: mock)
        let stream = singleSegmentStream(makeSegment())
        try await service.activate(stream: stream)
        // Activation succeeded — no throw
    }

    @Test("activate is idempotent — second call is no-op")
    func activateIsIdempotent() async throws {
        let mock = MockAsrTranscriber()
        let service = makeService(mock: mock)
        let stream1 = singleSegmentStream(makeSegment())
        let stream2 = singleSegmentStream(makeSegment())
        try await service.activate(stream: stream1)
        try await service.activate(stream: stream2) // Should not throw or double-process
    }

    // MARK: - Transcription

    @Test("Transcription emits result for high-confidence segment")
    func transcriptionEmitsHighConfidence() async throws {
        let mock = MockAsrTranscriber()
        await mock.stubResult(text: "hello world", confidence: 0.95, duration: 2.0)

        let service = makeService(mock: mock)
        var results: [TranscriptionResult] = []

        let streamTask = Task {
            for await result in service.transcriptionStream {
                results.append(result)
            }
        }

        let stream = singleSegmentStream(makeSegment())
        try await service.activate(stream: stream)

        // Allow the processing loop to complete
        try await Task.sleep(for: .milliseconds(100))
        await service.deactivate()
        streamTask.cancel()

        #expect(results.count == 1)
        #expect(results.first?.text == "hello world")
        #expect(results.first?.confidence == 0.95)
    }

    @Test("Transcription discards low-confidence result")
    func transcriptionDiscardsLowConfidence() async throws {
        let mock = MockAsrTranscriber()
        // Default minimumConfidence is 0.60; stub below threshold
        await mock.stubResult(text: "unclear", confidence: 0.40)

        var config = STTConfiguration()
        config.minimumConfidence = 0.60
        let service = makeService(config: config, mock: mock)

        var results: [TranscriptionResult] = []
        let streamTask = Task {
            for await result in service.transcriptionStream {
                results.append(result)
            }
        }

        let stream = singleSegmentStream(makeSegment())
        try await service.activate(stream: stream)
        try await Task.sleep(for: .milliseconds(100))
        await service.deactivate()
        streamTask.cancel()

        #expect(results.isEmpty)
    }

    @Test("Transcription result carries correct locale")
    func transcriptionResultHasCorrectLocale() async throws {
        let mock = MockAsrTranscriber()
        await mock.stubResult(text: "test", confidence: 0.9)

        let locale = Locale(identifier: "en-AU")
        let service = makeService(locale: locale, mock: mock)

        var results: [TranscriptionResult] = []
        let streamTask = Task {
            for await result in service.transcriptionStream {
                results.append(result)
            }
        }

        let stream = singleSegmentStream(makeSegment())
        try await service.activate(stream: stream)
        try await Task.sleep(for: .milliseconds(100))
        await service.deactivate()
        streamTask.cancel()

        #expect(results.first?.locale == locale)
    }

    // MARK: - Segment truncation

    @Test("Segment exceeding 240 000 samples is truncated before transcription")
    func longSegmentTruncated() async throws {
        let mock = MockAsrTranscriber()
        await mock.stubResult(text: "ok", confidence: 0.9)

        let service = makeService(mock: mock)
        let stream = singleSegmentStream(makeSegment(frameCount: 300_000))

        var results: [TranscriptionResult] = []
        let streamTask = Task {
            for await result in service.transcriptionStream {
                results.append(result)
            }
        }

        try await service.activate(stream: stream)
        try await Task.sleep(for: .milliseconds(100))
        await service.deactivate()
        streamTask.cancel()

        // Verify mock received exactly maxSamples
        let received = await mock.receivedSamples
        #expect(received.first?.count == 240_000)
        // Result still emitted after truncation
        #expect(results.count == 1)
    }

    @Test("Segment at exactly 240 000 samples is not truncated")
    func exactMaxSamplesNotTruncated() async throws {
        let mock = MockAsrTranscriber()
        await mock.stubResult(text: "ok", confidence: 0.9)

        let service = makeService(mock: mock)
        let stream = singleSegmentStream(makeSegment(frameCount: 240_000))

        let streamTask = Task {
            for await _ in service.transcriptionStream { }
        }

        try await service.activate(stream: stream)
        try await Task.sleep(for: .milliseconds(100))
        await service.deactivate()
        streamTask.cancel()

        let received = await mock.receivedSamples
        #expect(received.first?.count == 240_000)
    }

    // MARK: - Error handling

    @Test("Transcription error from mock does not crash or emit result")
    func transcriptionErrorDoesNotCrash() async throws {
        let mock = MockAsrTranscriber()
        await mock.stubError(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "inference error"]))

        let service = makeService(mock: mock)
        var results: [TranscriptionResult] = []
        let streamTask = Task {
            for await result in service.transcriptionStream {
                results.append(result)
            }
        }

        let stream = singleSegmentStream(makeSegment())
        try await service.activate(stream: stream)
        try await Task.sleep(for: .milliseconds(100))
        await service.deactivate()
        streamTask.cancel()

        // No crash; no result emitted on error
        #expect(results.isEmpty)
    }

    // MARK: - Metrics

    @Test("Transcription records metrics in STTMetricsCollector")
    func transcriptionRecordsMetrics() async throws {
        let mock = MockAsrTranscriber()
        await mock.stubResult(text: "hello", confidence: 0.9)

        let service = makeService(mock: mock)

        // Reset shared collector to isolate this test
        await STTMetricsCollector.shared.reset()

        let streamTask = Task {
            for await _ in service.transcriptionStream { }
        }

        let stream = singleSegmentStream(makeSegment())
        try await service.activate(stream: stream)
        try await Task.sleep(for: .milliseconds(100))
        await service.deactivate()
        streamTask.cancel()

        let recentMetrics = await STTMetricsCollector.shared.recent
        #expect(!recentMetrics.isEmpty)
        #expect(recentMetrics.last?.engine == .parakeet)
    }

    // MARK: - deactivate

    @Test("deactivate without activate does not crash")
    func deactivateWithoutActivate() async {
        let mock = MockAsrTranscriber()
        let service = makeService(mock: mock)
        await service.deactivate() // Should be safe
    }

    @Test("Multiple activate/deactivate cycles work correctly")
    func multipleActivateDeactivateCycles() async throws {
        let mock = MockAsrTranscriber()
        await mock.stubResult(text: "cycle test", confidence: 0.9)

        let service = makeService(mock: mock)

        for _ in 1...3 {
            let stream = singleSegmentStream(makeSegment())
            try await service.activate(stream: stream)
            try await Task.sleep(for: .milliseconds(50))
            await service.deactivate()
        }

        let callCount = await mock.callCount
        // 3 segments, each producing one transcription call
        #expect(callCount == 3)
    }

    // MARK: - AVAudioPCMBuffer.toFloatSamples

    @Test("toFloatSamples returns correct count for 16kHz buffer")
    func toFloatSamplesCount() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1000)!
        buffer.frameLength = 1000
        let samples = buffer.toFloatSamples()
        #expect(samples.count == 1000)
    }

    @Test("toFloatSamples returns empty array for buffer with no float channel data")
    func toFloatSamplesEmptyForNonFloat() {
        // Int16 format has no floatChannelData
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
        buffer.frameLength = 100
        let samples = buffer.toFloatSamples()
        #expect(samples.isEmpty)
    }
}
