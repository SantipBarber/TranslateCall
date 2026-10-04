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
        let cached = await manager.isModelCached()
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
}
