import Foundation
import Testing
@testable import TranslateCall

// MARK: - QwenCloneModelManagerTests

@Suite("QwenCloneModelManager")
@MainActor
struct QwenCloneModelManagerTests {

    private func makeManager(
        shouldFail: Bool = false
    ) -> QwenCloneModelManager {
        let loader: QwenCloneModelManager.ModelLoader = { _ in
            if shouldFail {
                throw QwenCloneError.downloadFailed("test error")
            }
            // Return a dummy — we don't call synthesize() in these tests
            // QwenCloneClient requires a real SpeechGenerationModel, so
            // we test via the state machine only (getInferrer checked separately)
            throw QwenCloneError.modelNotReady // placeholder
        }
        return QwenCloneModelManager(modelLoader: loader)
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

    @Test("getInferrer throws when not ready")
    func getInferrerThrowsWhenNotReady() async {
        let manager = makeManager()
        do {
            _ = try await manager.getInferrer()
            Issue.record("Expected error")
        } catch {
            #expect(error is QwenCloneError)
        }
    }

    @Test("unload transitions to idle")
    func unloadTransitionsToIdle() async {
        let manager = makeManager()
        // Try to load (will fail with placeholder), then unload
        _ = try? await manager.ensureReady()
        await manager.unload()
        let state = await manager.state
        guard case .idle = state else {
            Issue.record("Expected .idle after unload, got \(state)")
            return
        }
    }

    @Test("isModelCached returns false for fresh install")
    func isModelCachedReturnsFalseForFreshInstall() async {
        // Use a repo name that definitely doesn't exist in cache
        let config = QwenCloneConfiguration(
            modelRepo: "test-nonexistent/model-that-does-not-exist-\(UUID().uuidString)"
        )
        let manager = QwenCloneModelManager(config: config)
        let cached = await manager.isModelCached()
        #expect(!cached)
    }

    @Test("stateStream emits transitions")
    func stateStreamEmitsTransitions() async {
        let manager = makeManager()
        var emitted: [String] = []

        // Collect states in background
        let collectTask = Task {
            for await state in manager.stateStream {
                switch state {
                case .idle: emitted.append("idle")
                case .downloading: emitted.append("downloading")
                case .loading: emitted.append("loading")
                case .ready: emitted.append("ready")
                case .failed: emitted.append("failed")
                }
                // Stop after we see failed or idle (unload)
                if emitted.count >= 3 { break }
            }
        }

        // Trigger load (will fail) then unload
        _ = try? await manager.ensureReady()
        await manager.unload()

        // Give stream time to deliver
        try? await Task.sleep(for: .milliseconds(50))
        collectTask.cancel()

        // Should have seen: downloading → failed → idle
        #expect(emitted.contains("downloading"))
        #expect(emitted.contains("idle"))
    }
}
