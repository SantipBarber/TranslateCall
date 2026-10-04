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
