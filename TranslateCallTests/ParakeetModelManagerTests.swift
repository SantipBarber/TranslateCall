import Foundation
import Testing
@testable import TranslateCall

// MARK: - ParakeetModelManagerTests

/// Unit tests for `ParakeetModelManager` state machine.
///
/// All tests use isolated manager instances with injected factory closures so no
/// real CoreML model is downloaded or loaded.
@Suite("ParakeetModelManager", .serialized)
@MainActor
struct ParakeetModelManagerTests {

    // MARK: - Helpers

    enum TestError: Error { case downloadFailed }

    /// Creates a manager whose factory immediately returns a mock `AsrTranscriber`.
    ///
    /// Using `any AsrTranscriber` in the factory lets tests inject `MockAsrTranscriber`
    /// without importing FluidAudio or loading a real CoreML model.
    /// We verify the manager's *state machine* via the state stream and `modelState` property.
    func makeManager(
        factory: @escaping @Sendable (ParakeetConfiguration) async throws -> any AsrTranscriber
    ) -> ParakeetModelManager {
        ParakeetModelManager(managerFactory: factory)
    }

    // MARK: - Initial state

    @Test("Manager starts in .idle state")
    func startsIdle() async {
        let manager = makeManager { _ in throw TestError.downloadFailed }
        let state = await manager.modelState
        guard case .idle = state else {
            Issue.record("Expected .idle, got \(state)")
            return
        }
    }

    // MARK: - Failure path

    @Test("ensureReady sets .failed when factory throws")
    func ensureReadySetsFailedOnError() async {
        let manager = makeManager { _ in throw TestError.downloadFailed }

        do {
            _ = try await manager.ensureReady()
            Issue.record("Expected throw, got success")
        } catch {
            let state = await manager.modelState
            guard case .failed = state else {
                Issue.record("Expected .failed state, got \(state)")
                return
            }
        }
    }

    @Test("Failed state emitted on stateStream")
    func failedStateEmittedOnStream() async {
        let manager = makeManager { _ in throw TestError.downloadFailed }

        // Collect states from stream
        var collectedStates: [ParakeetModelManager.ModelState] = []
        let task = Task {
            for await state in manager.stateStream {
                collectedStates.append(state)
                if case .failed = state { break }
                if case .ready = state { break }
            }
        }

        // Trigger load
        _ = try? await manager.ensureReady()

        await finish(task)

        // Should have seen .loading then .failed
        #expect(collectedStates.contains { if case .loading = $0 { true } else { false } })
        #expect(collectedStates.contains { if case .failed = $0 { true } else { false } })
    }

    // MARK: - Concurrent callers

    @Test("Concurrent callers share the same in-flight task")
    func concurrentCallersShareTask() async throws {
        let factoryCallCount = CallCounter()
        // Simulate a slow factory
        let manager = makeManager { _ in
            factoryCallCount.increment()
            try await Task.sleep(for: .milliseconds(30))
            throw TestError.downloadFailed // still fails — we only care about call count
        }

        // Launch 5 concurrent callers
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    _ = try? await manager.ensureReady()
                }
            }
        }

        // Factory should have been called exactly once despite 5 concurrent callers
        #expect(factoryCallCount.value == 1)
    }

    // MARK: - unload

    @Test("unload transitions state back to .idle")
    func unloadResetsToIdle() async {
        let manager = makeManager { _ in throw TestError.downloadFailed }
        // Prime into failed state
        _ = try? await manager.ensureReady()

        await manager.unload()

        let state = await manager.modelState
        guard case .idle = state else {
            Issue.record("Expected .idle after unload, got \(state)")
            return
        }
    }

    @Test("After unload, ensureReady can be called again (retry)")
    func afterUnloadCanRetry() async {
        let callCount = CallCounter()
        let manager = makeManager { _ in
            callCount.increment()
            throw TestError.downloadFailed
        }

        _ = try? await manager.ensureReady()  // first attempt
        #expect(callCount.value == 1)

        await manager.unload()

        _ = try? await manager.ensureReady()  // retry after unload
        #expect(callCount.value == 2)
    }

    // MARK: - ModelState Equatable

    @Test("ModelState.idle == .idle")
    func modelStateIdleEquatable() {
        let state: ParakeetModelManager.ModelState = .idle
        #expect(state == .idle)
    }

    @Test("ModelState.loading == .loading")
    func modelStateLoadingEquatable() {
        let state: ParakeetModelManager.ModelState = .loading
        #expect(state == .loading)
    }

    @Test("ModelState.ready == .ready")
    func modelStateReadyEquatable() {
        let state: ParakeetModelManager.ModelState = .ready
        #expect(state == .ready)
    }

    @Test("ModelState.failed is equal by associated value")
    func modelStateFailedEquatable() {
        let stateA: ParakeetModelManager.ModelState = .failed("error A")
        let stateB: ParakeetModelManager.ModelState = .failed("error A")
        let stateC: ParakeetModelManager.ModelState = .failed("error B")
        #expect(stateA == stateB)
        #expect(stateA != stateC)
    }
}
