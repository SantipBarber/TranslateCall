import Foundation
import Testing
@testable import TranslateCall

// MARK: - QwenCloneModelManagerTests

@Suite("QwenCloneModelManager")
@MainActor
struct QwenCloneModelManagerTests {

    private func makeManager(
        inferrer: MockQwenCloneInferrer? = nil,
        gate: MLXInferenceGate = MLXInferenceGate()
    ) -> QwenCloneModelManager {
        let loader: QwenCloneModelManager.ModelLoader = { _ in
            guard let inferrer else { throw QwenCloneError.downloadFailed("test error") }
            return inferrer
        }
        return QwenCloneModelManager(modelLoader: loader, gate: gate)
    }

    @Test("Initial state is idle")
    func initialStateIsIdle() async {
        let manager = makeManager()
        let state = await manager.state
        guard case .idle = state else {
            Issue.record("Expected .idle, got \(state)")
            return
        }
    }

    @Test("synthesize throws modelNotReady before the model is loaded")
    func synthesizeThrowsWhenNotReady() async {
        let manager = makeManager(inferrer: MockQwenCloneInferrer())
        await #expect(throws: QwenCloneError.modelNotReady) {
            _ = try await manager.synthesize(text: "Hi", referenceAudio: [0], referenceTranscript: "x", language: "english")
        }
    }

    @Test("synthesize runs the loaded inferrer through the gate; the gated inferrer forwards to it (REQ-T-31)")
    func synthesizeGoesThroughTheGate() async throws {
        let inferrer = MockQwenCloneInferrer()
        let manager = makeManager(inferrer: inferrer)
        try await manager.ensureReady()

        let gated = manager.gatedInferrer()
        let samples = try await gated.synthesize(text: "Hola", referenceAudio: [0.1], referenceTranscript: "x",
                                                 language: "spanish")

        #expect(!samples.isEmpty)
        #expect(await inferrer.callCount == 1)
        #expect(await inferrer.lastLanguage == "spanish")
        #expect(gated.sampleRate == 24_000)
    }

    @Test("unload transitions to idle; later synthesis fails fast")
    func unloadTransitionsToIdle() async throws {
        let manager = makeManager(inferrer: MockQwenCloneInferrer())
        try await manager.ensureReady()
        await manager.unload()
        let state = await manager.state
        guard case .idle = state else {
            Issue.record("Expected .idle after unload, got \(state)")
            return
        }
        await #expect(throws: QwenCloneError.modelNotReady) {
            _ = try await manager.synthesize(text: "Hi", referenceAudio: [0], referenceTranscript: "x", language: "english")
        }
    }

    @Test("isModelCached returns false for fresh install")
    func isModelCachedReturnsFalseForFreshInstall() async {
        let config = QwenCloneConfiguration(
            modelRepo: "test-nonexistent/model-that-does-not-exist-\(UUID().uuidString)"
        )
        let manager = QwenCloneModelManager(config: config, modelLoader: { _ in MockQwenCloneInferrer() })
        let cached = manager.isModelCached()
        #expect(!cached)
    }

    @Test("stateStream emits transitions")
    func stateStreamEmitsTransitions() async {
        let manager = makeManager()
        var emitted: [String] = []

        let collectTask = Task {
            for await state in manager.stateStream {
                switch state {
                case .idle: emitted.append("idle")
                case .downloading: emitted.append("downloading")
                case .loading: emitted.append("loading")
                case .ready: emitted.append("ready")
                case .failed: emitted.append("failed")
                }
                if emitted.count >= 3 { break }
            }
        }

        _ = try? await manager.ensureReady()   // the loader throws: downloading → failed
        await manager.unload()

        await finish(collectTask)

        #expect(emitted.contains("downloading"))
        #expect(emitted.contains("idle"))
    }

    // MARK: - Streaming

    private let streamArgs = (text: "Hi", audio: [Float]([0]), transcript: "x", language: "english")

    private func stream(_ manager: QwenCloneModelManager) async -> AsyncThrowingStream<QwenStreamEvent, Error> {
        await manager.synthesizeStream(text: streamArgs.text, referenceAudio: streamArgs.audio,
                                       referenceTranscript: streamArgs.transcript, language: streamArgs.language)
    }

    private func firstEvent(of stream: AsyncThrowingStream<QwenStreamEvent, Error>) async throws {
        for try await _ in stream { return }
    }

    @Test("a stream on an idle manager throws modelNotReady")
    func streamNotReady() async {
        let manager = makeManager(inferrer: MockQwenCloneInferrer(), gate: MLXInferenceGate(clock: TestClock()))
        let failing = await stream(manager)
        await #expect(throws: QwenCloneError.modelNotReady) { try await firstEvent(of: failing) }
    }

    @Test("a ready manager relays the model's events in order through the gate")
    func streamThroughGate() async throws {
        let inferrer = MockQwenCloneInferrer()
        let events: [QwenStreamEvent] = [.audio([0.1]), .audio([0.2]), .info(tokens: 4, tokensPerSecond: 20)]
        await inferrer.setStubStream(events)
        let manager = makeManager(inferrer: inferrer, gate: MLXInferenceGate(clock: TestClock()))
        try await manager.ensureReady()

        var collected: [QwenStreamEvent] = []
        for try await event in await stream(manager) { collected.append(event) }

        #expect(collected == events)
        #expect(inferrer.streamCallCount == 1)
    }

    @Test("while an abandoned stream holds the gate, a new stream fails fast with gateBusyAbandoned")
    func abandonedFailsFast() async throws {
        let gate = MLXInferenceGate(clock: TestClock())
        let inferrer = MockQwenCloneInferrer()
        await inferrer.setStubStream([.audio([0.1]), .audio([0.2])], holdBefore: 1)
        let manager = makeManager(inferrer: inferrer, gate: gate)
        try await manager.ensureReady()

        let seen = LockedArray<QwenStreamEvent>()
        let first = await stream(manager)
        let caller = Task { for try await event in first { seen.append(event) } }
        #expect(await waitUntil { seen.values.count == 1 })
        caller.cancel()
        #expect(await waitUntil { await gate.isHeldByAbandonedStream })

        let failing = await stream(manager)
        await #expect(throws: QwenCloneError.gateBusyAbandoned) { try await firstEvent(of: failing) }
        #expect(inferrer.streamCallCount == 1, "the failing sentence reached the busy model")

        inferrer.gate.open()
        #expect(await waitUntil { !(await gate.isBusy) })
    }

    @Test("no audio within 3 s of the call: inferenceTimeout; an .info alone does not stop the timer (REQ-QS-03)")
    func firstChunkTimeoutIgnoresInfo() async throws {
        let clock = TestClock()
        let gate = MLXInferenceGate(clock: clock)
        let inferrer = MockQwenCloneInferrer()
        await inferrer.setStubStream([.info(tokens: 2, tokensPerSecond: 10), .audio([0.1])], holdBefore: 1)
        let manager = makeManager(inferrer: inferrer, gate: gate)
        try await manager.ensureReady()

        let seen = LockedArray<QwenStreamEvent>()
        let failures = LockedArray<QwenCloneError>()
        let events = await stream(manager)
        let caller = Task {
            do {
                for try await event in events { seen.append(event) }
            } catch {
                if let error = error as? QwenCloneError { failures.append(error) }
            }
        }
        #expect(await waitUntil { seen.values.count == 1 && clock.pendingDeadlines == [.seconds(3)] })
        clock.advance(by: .milliseconds(2_999))
        #expect(clock.sleeperCount == 1, "the timer stopped before its 3 s")
        clock.advance(by: .milliseconds(1))

        #expect(await waitUntil { failures.values == [.inferenceTimeout] })
        #expect(seen.values == [.info(tokens: 2, tokensPerSecond: 10)])
        caller.cancel()
        inferrer.gate.open()
        #expect(await waitUntil { !(await gate.isBusy) })
    }

    @Test("an unload while a stream queues for the gate: no inference on the unloaded model (REQ-QS-08)")
    func unloadWhileQueuedEndsStream() async throws {
        let gate = MLXInferenceGate(clock: TestClock())
        let inferrer = MockQwenCloneInferrer()
        let manager = makeManager(inferrer: inferrer, gate: gate)
        try await manager.ensureReady()
        try await gate.acquire(waitLimit: .seconds(2))   // another inference holds the gate

        let failures = LockedArray<QwenCloneError>()
        let events = await stream(manager)             // saw the model ready, now queues for the gate
        let caller = Task {
            do {
                for try await _ in events {}
            } catch {
                if let error = error as? QwenCloneError { failures.append(error) }
            }
        }
        #expect(await waitUntil { await gate.waitingCount == 1 })

        let unloaded = LockedArray<String>()
        let unloading = Task {
            await manager.unload()
            unloaded.append("unloaded")
        }
        #expect(await waitUntil {
            if case .idle = await manager.state { true } else { false }
        })
        await gate.release()                           // the queued stream is handed the gate

        #expect(await waitUntil { failures.values == [.modelNotReady] })
        await unloading.value
        await caller.value
        #expect(inferrer.streamCallCount == 0, "the stream ran on an unloaded model")
        #expect(unloaded.values == ["unloaded"])
        #expect(!(await gate.isBusy))
    }

    @Test("unload waits for an abandoned stream's model to finish")
    func unloadWaitsForStreamDrain() async throws {
        let gate = MLXInferenceGate(clock: TestClock())
        let inferrer = MockQwenCloneInferrer()
        await inferrer.setStubStream([.audio([0.1]), .audio([0.2])], holdBefore: 1)
        let manager = makeManager(inferrer: inferrer, gate: gate)
        try await manager.ensureReady()

        let seen = LockedArray<QwenStreamEvent>()
        let first = await stream(manager)
        let caller = Task { for try await event in first { seen.append(event) } }
        #expect(await waitUntil { seen.values.count == 1 })
        caller.cancel()
        #expect(await waitUntil { await gate.isHeldByAbandonedStream })

        let returned = LockedArray<String>()
        let unloading = Task {
            await manager.unload()
            returned.append("unloaded")
        }
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { !returned.values.isEmpty }))

        inferrer.gate.open()
        await unloading.value

        #expect(returned.values == ["unloaded"])
        guard case .idle = await manager.state else {
            Issue.record("Expected .idle after unload")
            return
        }
    }

    // MARK: - Warm-up (REQ-QS-31)

    private let profileId = UUID()

    /// A store holding the active profile, with reference audio and transcript.
    private func profileStore() async -> MockVoiceProfileStore {
        let header = VoiceProfileHeader(
            id: profileId, name: "Test", createdAt: .now, durationSeconds: 5, sampleRate: 24_000,
            sampleCount: 4,
            quality: VoiceQualityMetrics(peakRmsDbfs: -20, hasClipping: false, voicedDurationSeconds: 5, grade: .good),
            formatVersion: 1
        )
        let store = MockVoiceProfileStore()
        await store.forceStore(VoiceProfile(header: header, samples: [0.1, 0.2, 0.3, 0.4], transcript: "Hola"))
        return store
    }

    @Test("the warm-up runs one short sentence through the gate and drains it; the gate is idle after it")
    func warmUpDrainsThroughGate() async throws {
        let gate = MLXInferenceGate(clock: TestClock())
        let inferrer = MockQwenCloneInferrer()
        await inferrer.setStubStream([.audio([0.1]), .audio([0.2]), .info(tokens: 4, tokensPerSecond: 20)])
        let manager = makeManager(inferrer: inferrer, gate: gate)
        try await manager.ensureReady()

        await manager.warmUp(profileStore: await profileStore(), activeProfileId: profileId,
                             locale: Locale(identifier: "es-ES"))

        #expect(inferrer.streamCallCount == 1)
        #expect(await inferrer.lastText == "Hola.")
        #expect(await inferrer.lastLanguage == "spanish")
        #expect(await inferrer.lastReferenceAudioCount == 4)
        #expect(!(await gate.isBusy))
    }

    @Test("the warm-up text follows the target locale")
    func warmUpText() {
        #expect(QwenCloneModelManager.warmUpText(for: Locale(identifier: "es-MX")) == "Hola.")
        #expect(QwenCloneModelManager.warmUpText(for: Locale(identifier: "en-US")) == "Hello.")
        #expect(QwenCloneModelManager.warmUpText(for: Locale(identifier: "de-DE")) == "Hello.")
    }

    @Test("no warm-up while the model is not loaded, and a failing profile load is swallowed")
    func warmUpSkipsQuietly() async throws {
        let inferrer = MockQwenCloneInferrer()
        let manager = makeManager(inferrer: inferrer, gate: MLXInferenceGate(clock: TestClock()))
        await manager.warmUp(profileStore: await profileStore(), activeProfileId: profileId,
                             locale: Locale(identifier: "en-US"))
        #expect(inferrer.streamCallCount == 0)

        try await manager.ensureReady()
        await manager.warmUp(profileStore: MockVoiceProfileStore(), activeProfileId: profileId,
                             locale: Locale(identifier: "en-US"))
        #expect(inferrer.streamCallCount == 0, "no profile: nothing to warm with")
    }

    @Test("a cancelled warm-up returns at once; the gate drains the model, then opens (REQ-QS-06)")
    func cancelledWarmUpDrains() async throws {
        let gate = MLXInferenceGate(clock: TestClock())
        let inferrer = MockQwenCloneInferrer()
        await inferrer.setStubStream([.audio([0.1]), .audio([0.2])], holdBefore: 1)
        let manager = makeManager(inferrer: inferrer, gate: gate)
        try await manager.ensureReady()
        let store = await profileStore()

        let warmUp = Task {
            await manager.warmUp(profileStore: store, activeProfileId: profileId, locale: Locale(identifier: "en-US"))
        }
        #expect(await waitUntil { inferrer.streamCallCount == 1 })
        warmUp.cancel()
        await warmUp.value

        #expect(await waitUntil { await gate.isHeldByAbandonedStream })
        inferrer.gate.open()
        #expect(await waitUntil { !(await gate.isBusy) })
    }

    @Test("two warm-ups after one load run one inference; unload and load warm again")
    func warmUpOncePerLoad() async throws {
        let inferrer = MockQwenCloneInferrer()
        await inferrer.setStubStream([.audio([0.1]), .info(tokens: 4, tokensPerSecond: 20)])
        let manager = makeManager(inferrer: inferrer, gate: MLXInferenceGate(clock: TestClock()))
        let store = await profileStore()
        let locale = Locale(identifier: "en-US")
        try await manager.ensureReady()

        await manager.warmUp(profileStore: store, activeProfileId: profileId, locale: locale)
        await manager.warmUp(profileStore: store, activeProfileId: profileId, locale: locale)
        #expect(inferrer.streamCallCount == 1)

        await manager.unload()
        try await manager.ensureReady()
        await manager.warmUp(profileStore: store, activeProfileId: profileId, locale: locale)
        #expect(inferrer.streamCallCount == 2)
    }

    @Test("a warm-up that produced no audio does not count as warmed")
    func emptyWarmUpIsRetried() async throws {
        let inferrer = MockQwenCloneInferrer()
        await inferrer.setStubStream([])
        let manager = makeManager(inferrer: inferrer, gate: MLXInferenceGate(clock: TestClock()))
        let store = await profileStore()
        try await manager.ensureReady()
        await manager.warmUp(profileStore: store, activeProfileId: profileId, locale: Locale(identifier: "en-US"))
        await manager.warmUp(profileStore: store, activeProfileId: profileId, locale: Locale(identifier: "en-US"))
        #expect(inferrer.streamCallCount == 2)
    }

    @Test("a warm-up still draining across unload and reload does not mark the new model warm")
    func staleWarmUpDoesNotWarmReloadedModel() async throws {
        let inferrer = MockQwenCloneInferrer()
        await inferrer.setStubStream([.audio([0.1]), .audio([0.2])], holdBefore: 1)
        let manager = makeManager(inferrer: inferrer, gate: MLXInferenceGate(clock: TestClock()))
        let store = await profileStore()
        let locale = Locale(identifier: "en-US")
        try await manager.ensureReady()

        let oldWarmUp = Task {
            await manager.warmUp(profileStore: store, activeProfileId: profileId, locale: locale)
        }
        #expect(await waitUntil { inferrer.streamCallCount == 1 })
        let unloading = Task { await manager.unload() }   // waits for the gate, which the warm-up holds
        #expect(await waitUntil { if case .idle = await manager.state { true } else { false } })
        try await manager.ensureReady()   // the reload happens while the old warm-up still drains
        inferrer.gate.open()
        await oldWarmUp.value
        await unloading.value

        await manager.warmUp(profileStore: store, activeProfileId: profileId, locale: locale)
        #expect(inferrer.streamCallCount == 2, "the new, cold model still gets its own warm-up")
    }
}
