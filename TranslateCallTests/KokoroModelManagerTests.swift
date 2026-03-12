import Foundation
import Testing
@testable import TranslateCall

// MARK: - KokoroModelManagerTests

/// Unit tests for `KokoroModelManager` state machine.
///
/// All tests use isolated manager instances with injected factory closures so no
/// real CoreML model is downloaded or loaded.
@Suite("KokoroModelManager", .serialized)
@MainActor
struct KokoroModelManagerTests {

    // MARK: - Helpers

    enum TestError: Error { case synthesizeFailed }

    func makeManager(
        factory: @escaping @Sendable (KokoroConfiguration) async throws -> any KokoroTtsManaging
    ) -> KokoroModelManager {
        KokoroModelManager(managerFactory: factory)
    }

    // MARK: - Initial state

    @Test("Manager starts in .idle state")
    func startsIdle() async {
        let manager = makeManager { _ in throw TestError.synthesizeFailed }
        let state = await manager.state
        guard case .idle = state else {
            Issue.record("Expected .idle, got \(state)")
            return
        }
    }

    // MARK: - Success path

    @Test("ensureReady returns manager when factory succeeds")
    func ensureReadyReturnsManagerOnSuccess() async throws {
        let mock = MockKokoroTtsManager()
        let manager = makeManager { _ in mock }
        let result = try await manager.ensureReady()
        // Verify we got a valid manager back (can synthesize without throwing)
        _ = try await result.synthesizeSamples(text: "test", voice: nil)
        let callCount = await mock.callCount
        #expect(callCount == 1)
    }

    @Test("Ready state emitted on stateStream after successful load")
    func readyStateEmittedOnStream() async throws {
        let mock = MockKokoroTtsManager()
        let manager = makeManager { _ in mock }

        var collectedStates: [KokoroModelManager.ModelState] = []
        let task = Task {
            for await state in manager.stateStream {
                collectedStates.append(state)
                if case .ready = state { break }
                if case .failed = state { break }
            }
        }

        _ = try await manager.ensureReady()
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        #expect(collectedStates.contains { if case .loading = $0 { true } else { false } })
        #expect(collectedStates.contains { if case .ready = $0 { true } else { false } })
    }

    // MARK: - Failure path

    @Test("ensureReady sets .failed when factory throws")
    func ensureReadySetsFailedOnError() async {
        let manager = makeManager { _ in throw TestError.synthesizeFailed }

        do {
            _ = try await manager.ensureReady()
            Issue.record("Expected throw, got success")
        } catch {
            let state = await manager.state
            guard case .failed = state else {
                Issue.record("Expected .failed state, got \(state)")
                return
            }
        }
    }

    @Test("Failed state emitted on stateStream")
    func failedStateEmittedOnStream() async {
        let manager = makeManager { _ in throw TestError.synthesizeFailed }

        var collectedStates: [KokoroModelManager.ModelState] = []
        let task = Task {
            for await state in manager.stateStream {
                collectedStates.append(state)
                if case .failed = state { break }
                if case .ready = state { break }
            }
        }

        _ = try? await manager.ensureReady()
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        #expect(collectedStates.contains { if case .loading = $0 { true } else { false } })
        #expect(collectedStates.contains { if case .failed = $0 { true } else { false } })
    }

    // MARK: - Concurrent callers

    @Test("Concurrent callers share the same in-flight task")
    func concurrentCallersShareTask() async throws {
        var factoryCallCount = 0
        let manager = makeManager { _ in
            factoryCallCount += 1
            try await Task.sleep(for: .milliseconds(30))
            throw TestError.synthesizeFailed
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    _ = try? await manager.ensureReady()
                }
            }
        }

        #expect(factoryCallCount == 1)
    }

    // MARK: - unload

    @Test("unload transitions state back to .idle")
    func unloadResetsToIdle() async {
        let manager = makeManager { _ in throw TestError.synthesizeFailed }
        _ = try? await manager.ensureReady()

        await manager.unload()

        let state = await manager.state
        guard case .idle = state else {
            Issue.record("Expected .idle after unload, got \(state)")
            return
        }
    }

    @Test("After unload, ensureReady can be called again (retry)")
    func afterUnloadCanRetry() async {
        var callCount = 0
        let manager = makeManager { _ in
            callCount += 1
            throw TestError.synthesizeFailed
        }

        _ = try? await manager.ensureReady()
        #expect(callCount == 1)

        await manager.unload()

        _ = try? await manager.ensureReady()
        #expect(callCount == 2)
    }

    // MARK: - redownload

    @Test("redownload unloads then reloads — factory called twice across two calls")
    func redownloadCallsFactoryAgain() async {
        var callCount = 0
        let manager = makeManager { _ in
            callCount += 1
            throw TestError.synthesizeFailed
        }

        _ = try? await manager.ensureReady()
        #expect(callCount == 1)

        _ = try? await manager.redownload()
        #expect(callCount == 2)
    }

    // MARK: - Second ensureReady hits .ready fast path

    @Test("Second ensureReady returns cached manager without re-loading")
    func secondEnsureReadyReturnsCached() async throws {
        var callCount = 0
        let mock = MockKokoroTtsManager()
        let manager = makeManager { _ in
            callCount += 1
            return mock
        }

        _ = try await manager.ensureReady()
        _ = try await manager.ensureReady()

        #expect(callCount == 1) // factory called only once
    }
}
