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

        inferrer.gate.open()
        #expect(await waitUntil { !(await gate.isBusy) })
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
}
