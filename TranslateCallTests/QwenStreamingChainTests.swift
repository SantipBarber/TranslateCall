import Foundation
import Testing
@testable import TranslateCall

// MARK: - QwenStreamingChainTests

/// The production voice-clone chain end to end, with only the model and the output faked:
/// `TTSPlaybackService` → `QwenUtteranceSynthesizer` → `GatedQwenInferrer` → `QwenCloneModelManager` →
/// `MLXInferenceGate` → `MockQwenCloneInferrer` (qwen-streaming REQ-QS-03/06/07/07a, G1 I1).
@Suite("Qwen streaming chain")
struct QwenStreamingChainTests {

    /// The wired chain. The gate and the service have their own clocks; only `gateClock` is ever advanced.
    private struct Chain {
        let inferrer = MockQwenCloneInferrer()
        let gateClock = TestClock()
        let gate: MLXInferenceGate
        let manager: QwenCloneModelManager
        let fallback = FakeSynthesizer(engine: .avSpeech)
        let output = FakeOutput(autoComplete: true)
        let service: TTSPlaybackService

        init(breakerThreshold: Int = 3) async throws {
            let profileId = UUID()
            let store = MockVoiceProfileStore()
            await store.forceStore(Self.profile(id: profileId))
            gate = MLXInferenceGate(clock: gateClock)
            let model = inferrer
            manager = QwenCloneModelManager(modelLoader: { _ in model }, gate: gate)
            try await manager.ensureReady()
            let clone = QwenUtteranceSynthesizer(activeProfileId: profileId, profileStore: store,
                                                 inferrer: manager.gatedInferrer())
            var limits = TTSPlaybackLimits.uncoalesced
            limits.breakerThreshold = breakerThreshold
            service = TTSPlaybackService(primary: clone, fallback: fallback, output: output,
                                         limits: limits, clock: TestClock(), metrics: TTSMetricsCollector(cap: 10))
        }

        private static func profile(id: UUID) -> VoiceProfile {
            let header = VoiceProfileHeader(
                id: id, name: "Test", createdAt: .now, durationSeconds: 5, sampleRate: 24_000, sampleCount: 2_400,
                quality: VoiceQualityMetrics(peakRmsDbfs: -20, hasClipping: false, voicedDurationSeconds: 5,
                                             grade: .good),
                formatVersion: 1
            )
            return VoiceProfile(header: header, samples: Array(repeating: 0.5, count: 2_400), transcript: "Hello")
        }

        /// Speaks `text` and waits until the fallback has spoken `count` sentences in all.
        func speakFallingBack(_ text: String, fallbackCount count: Int) async -> Bool {
            await service.speak(text: text, locale: english)
            return await waitUntil { fallback.texts.count == count }
        }

        /// Speaks `text` while the mock holds before its first chunk, and lets the 3 s first-chunk timer fire
        /// once the model has started (`modelCalls` in all), so the timed-out model is left holding the gate.
        func speakTimingOut(_ text: String, modelCalls: Int, fallbackCount count: Int) async -> Bool {
            await service.speak(text: text, locale: english)
            let started = await waitUntil { inferrer.streamCallCount == modelCalls && gateClock.sleeperCount == 1 }
            guard started else { return false }
            gateClock.advance(by: .seconds(3))
            return await waitUntil { fallback.texts.count == count }
        }

        /// Lets the held model finish and waits until it has given the gate back.
        func drainModel() async -> Bool {
            inferrer.gate.open()
            return await waitUntil { !(await gate.isBusy) }
        }
    }

    private let chunk = QwenStreamEvent.audio(Array(repeating: 0.1, count: 2_400))

    @Test("stop mid-sentence, speak again at once: the fallback speaks at once, outside the breaker (REQ-QS-07a)")
    func stopThenSpeakFallsBackAtOnce() async throws {
        let chain = try await Chain()
        await chain.inferrer.setStubStream([chunk, chunk], holdBefore: 1)
        await chain.service.speak(text: "s0", locale: english)
        #expect(await waitUntil { chain.output.scheduledCount == 1 })

        await chain.service.stopSpeaking()
        #expect(await waitUntil { await chain.gate.isHeldByAbandonedStream })

        for index in 1...3 {
            #expect(await chain.speakFallingBack("s\(index)", fallbackCount: index))   // no clock advance
        }
        #expect(chain.fallback.texts == ["s1", "s2", "s3"])
        #expect(chain.inferrer.streamCallCount == 1, "a sentence reached the model while it was still busy")
        #expect(!(await chain.service.isBreakerOpen))

        #expect(await chain.drainModel())
        await chain.service.speak(text: "s4", locale: english)
        #expect(await waitUntil { chain.output.scheduledCount == 6 })    // s0: 1, fallback: 3, s4: 2
        #expect(chain.inferrer.streamCallCount == 2)
        #expect(chain.fallback.texts.count == 3, "the clone did not speak once the model had finished")
        await chain.service.deactivate()
    }

    @Test("while abandoned, a first-chunk timeout counts toward the breaker and the fast failures do not")
    func timeoutsCountAbandonedFailuresDoNot() async throws {
        let chain = try await Chain(breakerThreshold: 2)
        await chain.inferrer.setStubStream([chunk], holdBefore: 0)

        #expect(await chain.speakTimingOut("s1", modelCalls: 1, fallbackCount: 1))        // failure 1
        #expect(await chain.gate.isHeldByAbandonedStream, "the timed-out model still holds the gate")
        #expect(await chain.speakFallingBack("s2", fallbackCount: 2))      // abandoned: not counted
        #expect(!(await chain.service.isBreakerOpen), "the abandoned failure counted toward the breaker")

        #expect(await chain.drainModel())
        chain.inferrer.rearmHold()
        #expect(await chain.speakTimingOut("s3", modelCalls: 2, fallbackCount: 3))   // failure 2: flag reset
        #expect(await chain.service.isBreakerOpen, "the timeout after an abandoned failure did not count")
        #expect(chain.inferrer.streamCallCount == 2)

        #expect(await chain.drainModel())
        await chain.service.deactivate()
    }
}
