import Foundation
import Testing
@testable import TranslateCall

// MARK: - QwenCloneSpeechServiceTests

@Suite(.serialized)
@MainActor
struct QwenCloneSpeechServiceTests {

    // MARK: - Test helpers

    private let testProfileId = UUID()

    private func makeTestProfile() -> VoiceProfile {
        let header = VoiceProfileHeader(
            id: testProfileId,
            name: "Test",
            createdAt: .now,
            durationSeconds: 5.0,
            sampleRate: 24000,
            sampleCount: 120_000,
            quality: VoiceQualityMetrics(
                peakRmsDbfs: -20, hasClipping: false,
                voicedDurationSeconds: 5.0, grade: .good
            ),
            formatVersion: 1
        )
        let samples = Array(repeating: Float(0.5), count: 120_000)
        return VoiceProfile(header: header, samples: samples, transcript: "Hello world test")
    }

    private func makeService(
        inferrer: MockQwenCloneInferrer? = nil,
        store: MockVoiceProfileStore? = nil
    ) throws -> (QwenCloneSpeechService, MockQwenCloneInferrer, MockVoiceProfileStore) {
        let inf = inferrer ?? MockQwenCloneInferrer()
        let st = store ?? MockVoiceProfileStore()
        let service = try QwenCloneSpeechService(
            outputDeviceID: nil,
            activeProfileId: testProfileId,
            profileStore: st,
            inferrer: inf
        )
        return (service, inf, st)
    }

    // MARK: - Tests

    @Test("speak calls inferrer with profile context")
    func speakCallsInferrerWithProfileContext() async throws {
        let (service, inferrer, store) = try makeService()
        let profile = makeTestProfile()
        await store.forceStore(profile)

        await service.speak(text: "Hola mundo", locale: Locale(identifier: "es-ES"))

        // Wait for async processing
        try await Task.sleep(for: .milliseconds(200))

        let count = await inferrer.callCount
        #expect(count >= 1)

        let lastText = await inferrer.lastText
        #expect(lastText == "Hola mundo")

        let refCount = await inferrer.lastReferenceAudioCount
        #expect(refCount == 120_000)
    }

    @Test("text truncated at 200 chars")
    func textTruncatedAt200Chars() async throws {
        let (service, inferrer, store) = try makeService()
        let profile = makeTestProfile()
        await store.forceStore(profile)

        let longText = String(repeating: "word ", count: 60) // 300 chars
        await service.speak(text: longText, locale: Locale(identifier: "en-US"))

        try await Task.sleep(for: .milliseconds(200))

        let lastText = await inferrer.lastText
        #expect((lastText?.count ?? 0) <= 200)
    }

    @Test("empty text ignored")
    func emptyTextIgnored() async throws {
        let (service, inferrer, _) = try makeService()

        await service.speak(text: "  ", locale: Locale(identifier: "en-US"))

        try await Task.sleep(for: .milliseconds(100))

        let count = await inferrer.callCount
        #expect(count == 0)
    }

    @Test("stop clears queue")
    func stopClearsQueue() async throws {
        let (service, _, store) = try makeService()
        let profile = makeTestProfile()
        await store.forceStore(profile)

        // Queue multiple
        await service.speak(text: "First", locale: Locale(identifier: "en-US"))
        await service.speak(text: "Second", locale: Locale(identifier: "en-US"))
        await service.stopSpeaking()

        let pending = await service.pendingTexts
        #expect(pending.isEmpty)
    }

    @Test("inference error continues queue")
    func inferenceErrorContinuesQueue() async throws {
        let inferrer = MockQwenCloneInferrer()
        await inferrer.setStubError(QwenCloneError.inferenceTimeout)

        let (service, _, store) = try makeService(inferrer: inferrer)
        let profile = makeTestProfile()
        await store.forceStore(profile)

        await service.speak(text: "Hello", locale: Locale(identifier: "en-US"))

        // Wait for error handling + processNext
        try await Task.sleep(for: .milliseconds(300))

        // Should have attempted synthesis (and failed)
        let count = await inferrer.callCount
        #expect(count >= 1)
    }

    @Test("conforms to SynthesisService protocol")
    func conformsToSynthesisServiceProtocol() async throws {
        let (service, _, _) = try makeService()
        // Compile-time check: QwenCloneSpeechService conforms to SynthesisService
        let _: any SynthesisService = service
        #expect(true)
    }

    @Test("language passed to inferrer")
    func languagePassedToInferrer() async throws {
        let (service, inferrer, store) = try makeService()
        let profile = makeTestProfile()
        await store.forceStore(profile)

        await service.speak(text: "Bonjour", locale: Locale(identifier: "fr-FR"))

        try await Task.sleep(for: .milliseconds(200))

        let lang = await inferrer.lastLanguage
        #expect(lang == "french")
    }

    @Test("inference timeout recovery")
    func inferenceTimeoutRecovery() async throws {
        let inferrer = MockQwenCloneInferrer()
        // Set delay longer than timeout (config default = 10s, but we'll use a short config)
        await inferrer.setStubDelay(.seconds(5))

        let shortConfig = QwenCloneConfiguration(inferenceTimeoutSeconds: 1)
        let store = MockVoiceProfileStore()
        let profile = makeTestProfile()
        await store.forceStore(profile)

        let service = try QwenCloneSpeechService(
            outputDeviceID: nil,
            activeProfileId: testProfileId,
            profileStore: store,
            inferrer: inferrer,
            config: shortConfig
        )

        await service.speak(text: "Hello", locale: Locale(identifier: "en-US"))

        // Wait for timeout + error handling
        try await Task.sleep(for: .seconds(2))

        // Service should have recovered (not hung)
        let pending = await service.pendingTexts
        #expect(pending.isEmpty)
    }
}
