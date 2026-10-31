import AVFoundation
import Foundation
import Testing
@testable import TranslateCall

@Suite("QwenUtteranceSynthesizer")
struct QwenUtteranceSynthesizerTests {
    private let profileId = UUID()

    private func profile(samples: [Float]? = Array(repeating: 0.5, count: 120_000)) -> VoiceProfile {
        let header = VoiceProfileHeader(
            id: profileId, name: "Test", createdAt: .now, durationSeconds: 5, sampleRate: 24_000,
            sampleCount: 120_000,
            quality: VoiceQualityMetrics(peakRmsDbfs: -20, hasClipping: false, voicedDurationSeconds: 5, grade: .good),
            formatVersion: 1
        )
        return VoiceProfile(header: header, samples: samples, transcript: "Hello world test")
    }

    private func make(_ inferrer: MockQwenCloneInferrer, store: MockVoiceProfileStore) -> QwenUtteranceSynthesizer {
        QwenUtteranceSynthesizer(activeProfileId: profileId, profileStore: store, inferrer: inferrer)
    }

    /// A synthesizer over a store holding the default profile.
    private func ready(_ inferrer: MockQwenCloneInferrer) async -> QwenUtteranceSynthesizer {
        let store = MockVoiceProfileStore()
        await store.forceStore(profile())
        return make(inferrer, store: store)
    }

    @Test("passes the profile's reference audio, transcript and language; yields one 24 kHz buffer")
    func synthesizesWithProfile() async throws {
        let inferrer = MockQwenCloneInferrer()
        let store = MockVoiceProfileStore()
        await store.forceStore(profile())
        let buffers = try #require(try await collect(make(inferrer, store: store)
            .synthesize(text: "Bonjour", locale: Locale(identifier: "fr-FR"))))

        #expect(buffers.count == 1)
        #expect(buffers.first?.format.sampleRate == 24_000)
        #expect(buffers.first?.frameLength == 2_400)
        #expect(await inferrer.lastText == "Bonjour")
        #expect(await inferrer.lastLanguage == "french")
        #expect(await inferrer.lastReferenceAudioCount == 120_000)
    }

    @Test("text longer than the limit is cut at a word boundary (REQ-T-04)")
    func truncates() async throws {
        let inferrer = MockQwenCloneInferrer()
        let store = MockVoiceProfileStore()
        await store.forceStore(profile())
        _ = try await collect(make(inferrer, store: store)
            .synthesize(text: String(repeating: "word ", count: 60), locale: english))
        let sent = try #require(await inferrer.lastText)
        #expect(sent.count <= 200)
        #expect(!sent.hasSuffix(" "))
    }

    @Test("an inference error fails the stream (so the playback service can fall back)")
    func inferenceErrorThrows() async {
        let inferrer = MockQwenCloneInferrer()
        await inferrer.setStubError(QwenCloneError.inferenceTimeout)
        let store = MockVoiceProfileStore()
        await store.forceStore(profile())
        await #expect(throws: QwenCloneError.inferenceTimeout) {
            _ = try await collect(make(inferrer, store: store).synthesize(text: "Hello", locale: english))
        }
    }

    @Test("a profile without audio fails with payloadMissing and never calls the model")
    func missingPayload() async {
        let inferrer = MockQwenCloneInferrer()
        let store = MockVoiceProfileStore()
        await store.forceStore(profile(samples: nil))
        await #expect(throws: VoiceProfileError.payloadMissing) {
            _ = try await collect(make(inferrer, store: store).synthesize(text: "Hello", locale: english))
        }
        #expect(await inferrer.callCount == 0)
        #expect(inferrer.streamCallCount == 0)
    }

    @Test("empty model output fails the stream instead of finishing silently")
    func emptyOutputThrows() async {
        let inferrer = MockQwenCloneInferrer()
        await inferrer.setStubSamples([])
        let store = MockVoiceProfileStore()
        await store.forceStore(profile())
        await #expect(throws: QwenCloneError.emptyOutput) {
            _ = try await collect(make(inferrer, store: store).synthesize(text: "Hello", locale: english))
        }
    }

    @Test("supports the Qwen languages only")
    func canSpeak() {
        let synthesizer = make(MockQwenCloneInferrer(), store: MockVoiceProfileStore())
        #expect(synthesizer.canSpeak(Locale(identifier: "es-ES")))
        #expect(!synthesizer.canSpeak(Locale(identifier: "hi-IN")))
    }
}

// MARK: - Streaming (REQ-QS-01/04)

extension QwenUtteranceSynthesizerTests {
    private static func audio(_ count: Int) -> QwenStreamEvent { .audio(Array(repeating: 0.1, count: count)) }

    @Test("each streamed audio chunk becomes one 24 kHz buffer, in order")
    func yieldsBufferPerChunk() async throws {
        let inferrer = MockQwenCloneInferrer()
        await inferrer.setStubStream([
            Self.audio(2_400), Self.audio(4_800), Self.audio(2_400), .info(tokens: 12, tokensPerSecond: 30)
        ])
        let buffers = try #require(try await collect(await ready(inferrer).synthesize(text: "Hi", locale: english)))

        #expect(buffers.map(\.frameLength) == [2_400, 4_800, 2_400])
        #expect(buffers.allSatisfy { $0.format.sampleRate == 24_000 })
        #expect(inferrer.streamCallCount == 1)
    }

    @Test("an empty audio chunk yields no buffer")
    func emptyChunksSkipped() async throws {
        let inferrer = MockQwenCloneInferrer()
        await inferrer.setStubStream([Self.audio(2_400), .audio([]), Self.audio(1_200)])
        let buffers = try #require(try await collect(await ready(inferrer).synthesize(text: "Hi", locale: english)))

        #expect(buffers.map(\.frameLength) == [2_400, 1_200])
    }

    @Test("a stream with no audio at all fails with emptyOutput")
    func noAudioThrowsEmpty() async {
        let inferrer = MockQwenCloneInferrer()
        await inferrer.setStubStream([.info(tokens: 0, tokensPerSecond: 0)])
        let synthesizer = await ready(inferrer)
        await #expect(throws: QwenCloneError.emptyOutput) {
            _ = try await collect(synthesizer.synthesize(text: "Hi", locale: english))
        }
    }

    @Test("an error after the first chunk reaches the consumer after that chunk's buffer")
    func errorAfterFirstChunk() async {
        let inferrer = MockQwenCloneInferrer()
        await inferrer.setStubStream([Self.audio(2_400), Self.audio(2_400)], failAfter: 1)
        let stream = await ready(inferrer).synthesize(text: "Hi", locale: english)

        let seen = LockedArray<AVAudioFrameCount>()
        await #expect(throws: MockQwenCloneError.failed) {
            for try await buffer in stream { seen.append(buffer.frameLength) }
        }
        #expect(seen.values == [2_400])
    }

    @Test("cancelling the consumer stops the buffers; the model is asked once")
    func consumerCancelStopsYielding() async throws {
        let inferrer = MockQwenCloneInferrer()
        await inferrer.setStubStream([Self.audio(2_400), Self.audio(2_400)], holdBefore: 1)
        let stream = await ready(inferrer).synthesize(text: "Hi", locale: english)

        let seen = LockedArray<AVAudioFrameCount>()
        let consumer = Task { for try await buffer in stream { seen.append(buffer.frameLength) } }
        #expect(await waitUntil { seen.values.count == 1 })
        #expect(await waitUntil { inferrer.gate.waiterCount == 1 })
        consumer.cancel()
        _ = await consumer.result
        inferrer.gate.open()
        #expect(await waitUntil { inferrer.gate.waiterCount == 0 })

        #expect(seen.values == [2_400])
        #expect(inferrer.streamCallCount == 1)
    }
}

@Suite("Voice clone sentence outcome")
struct SentenceOutcomeTests {
    @Test("the sentence log names how it ended: a stop is cancelled even when the relay ended without error (G1 M2)")
    func outcomes() {
        #expect(SentenceOutcome(ending: nil, cancelled: false) == .finished)
        #expect(SentenceOutcome(ending: nil, cancelled: true) == .cancelled)
        #expect(SentenceOutcome(ending: CancellationError(), cancelled: false) == .cancelled)
        #expect(SentenceOutcome(ending: QwenCloneError.inferenceTimeout, cancelled: true) == .cancelled)
        #expect(SentenceOutcome(ending: QwenCloneError.inferenceTimeout, cancelled: false) == .error)
        #expect(SentenceOutcome.cancelled.rawValue == "cancelled")
    }
}
