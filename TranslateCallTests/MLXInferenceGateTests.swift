import Foundation
import Synchronization
import Testing
@testable import TranslateCall

/// Counts how many gated "inferences" run at once.
private final class ConcurrencyProbe: Sendable {
    private let state = Mutex((running: 0, peak: 0, started: 0))

    var peak: Int { state.withLock { $0.peak } }
    var started: Int { state.withLock { $0.started } }

    func enter() {
        state.withLock { current in
            current.running += 1
            current.started += 1
            current.peak = max(current.peak, current.running)
        }
    }

    func leave() { state.withLock { $0.running -= 1 } }
}

@Suite("MLXInferenceGate")
struct MLXInferenceGateTests {

    @Test("at most one inference runs at a time; queued callers run in turn (REQ-T-30)")
    func oneAtATime() async throws {
        let gate = MLXInferenceGate(clock: TestClock())
        let probe = ConcurrencyProbe()
        let release = AsyncGate()
        let calls = (0..<3).map { index in
            Task {
                try await gate.run(wait: .seconds(2), inference: .seconds(10)) {
                    probe.enter()
                    defer { probe.leave() }
                    await release.wait()
                    return index
                }
            }
        }
        #expect(await waitUntil { await gate.waitingCount == 2 && probe.started == 1 })
        release.open()
        var results: [Int] = []
        for call in calls { results.append(try await call.value) }
        #expect(results.sorted() == [0, 1, 2])
        #expect(probe.peak == 1)
        #expect(!(await gate.isBusy))
    }

    @Test("an inference past its limit returns .inferenceTimeout while the gate stays closed until MLX returns (REQ-T-32)")
    func timeoutKeepsGateClosed() async throws {
        let clock = TestClock()
        let gate = MLXInferenceGate(clock: clock)
        let probe = ConcurrencyProbe()
        let slow = AsyncGate()
        let first = Task {
            try await gate.run(wait: .seconds(2), inference: .seconds(10)) {
                probe.enter()
                defer { probe.leave() }
                await slow.wait()
                return 1
            }
        }
        #expect(await waitUntil { probe.started == 1 && clock.pendingDeadlines == [.seconds(10)] })
        clock.advance(by: .seconds(10))
        await #expect(throws: QwenCloneError.inferenceTimeout) { try await first.value }
        #expect(await gate.isBusy, "the gate opened while MLX was still running")

        let second = Task { try await gate.run(wait: .seconds(2), inference: .seconds(10)) { probe.enter(); probe.leave(); return 2 } }
        #expect(await waitUntil { await gate.waitingCount == 1 })
        #expect(probe.started == 1, "a second inference started on top of the first")

        slow.open()                                   // MLX finally returns; its result is discarded
        #expect(try await second.value == 2)
        #expect(probe.peak == 1)
    }

    @Test("a caller that waits past the wait limit gets .gateBusy and its work never runs (REQ-T-32)")
    func gateBusy() async throws {
        let clock = TestClock()
        let gate = MLXInferenceGate(clock: clock)
        let hold = AsyncGate()
        let ran = ConcurrencyProbe()
        let first = Task { try await gate.run(wait: .seconds(2), inference: .seconds(10)) { await hold.wait(); return 1 } }
        #expect(await waitUntil { clock.sleeperCount == 1 })            // the first inference's limit
        let second = Task { try await gate.run(wait: .seconds(2), inference: .seconds(10)) { ran.enter(); return 2 } }
        #expect(await waitUntil { await gate.waitingCount == 1 && clock.sleeperCount == 2 })

        clock.advance(by: .seconds(2))

        await #expect(throws: QwenCloneError.gateBusy) { try await second.value }
        #expect(ran.started == 0)
        hold.open()
        #expect(try await first.value == 1)
    }

    @Test("waitUntilIdle returns once the running inference is done")
    func waitUntilIdle() async throws {
        let gate = MLXInferenceGate(clock: TestClock())
        let hold = AsyncGate()
        let running = Task { try await gate.run(wait: .seconds(2), inference: .seconds(10)) { await hold.wait(); return 0 } }
        #expect(await waitUntil { await gate.isBusy })
        let idle = Task { await gate.waitUntilIdle() }
        hold.open()
        await idle.value
        _ = try await running.value
        #expect(!(await gate.isBusy))
    }

    @Test("a cancelled queued caller leaves the queue, never runs, and the next caller gets the gate")
    func cancelledWaiterLeavesQueue() async throws {
        let gate = MLXInferenceGate(clock: TestClock())
        let hold = AsyncGate()
        let ran = ConcurrencyProbe()
        let first = Task { try await gate.run(wait: .seconds(2), inference: .seconds(10)) { await hold.wait(); return 1 } }
        #expect(await waitUntil { await gate.isBusy })
        let cancelled = Task { try await gate.run(wait: .seconds(2), inference: .seconds(10)) { ran.enter(); return 2 } }
        #expect(await waitUntil { await gate.waitingCount == 1 })
        let next = Task { try await gate.run(wait: .seconds(2), inference: .seconds(10)) { return 3 } }
        #expect(await waitUntil { await gate.waitingCount == 2 })

        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await waitUntil { await gate.waitingCount == 1 })

        hold.open()
        #expect(try await first.value == 1)
        #expect(try await next.value == 3)
        // Negative check: the cancelled work must not have run (bounded wait, nothing to wait for).
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { ran.started > 0 }))
        #expect(!(await gate.isBusy))
    }
}
