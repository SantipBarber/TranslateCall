import Foundation
import Synchronization
import Testing
@testable import TranslateCall

/// The model stream a test drives by hand (`continuation`), and how many times `work` asked for it.
private final class InnerStream: Sendable {
    let stream: AsyncThrowingStream<Int, Error>
    let continuation: AsyncThrowingStream<Int, Error>.Continuation
    private let calls = Mutex(0)

    init() {
        (stream, continuation) = AsyncThrowingStream<Int, Error>.makeStream()
    }

    var callCount: Int { calls.withLock { $0 } }

    func work() -> AsyncThrowingStream<Int, Error> {
        calls.withLock { $0 += 1 }
        return stream
    }
}

/// Listens to `stream` in a task the test can cancel (dropping an iterator does not end the stream).
private func consume(_ stream: AsyncThrowingStream<Int, Error>, into seen: LockedArray<Int>) -> Task<Void, Error> {
    Task {
        for try await element in stream { seen.append(element) }
    }
}

@Suite("MLXInferenceGate streaming")
struct MLXInferenceGateStreamTests {

    @Test("the model's elements reach the caller in order and the gate opens at the end (REQ-QS-06)")
    func relaysInOrder() async throws {
        let gate = MLXInferenceGate(clock: TestClock())
        let inner = InnerStream()
        let seen = LockedArray<Int>()
        let caller = consume(gate.runStream(firstElement: .seconds(3), work: { inner.work() }), into: seen)

        inner.continuation.yield(1)
        inner.continuation.yield(2)
        inner.continuation.yield(3)
        inner.continuation.finish()

        try await caller.value
        #expect(seen.values == [1, 2, 3])
        #expect(!(await gate.isBusy))
    }

    @Test("an abandoned stream keeps the gate closed until the model stream ends (REQ-QS-06, 07)")
    func abandonedKeepsGateUntilInnerEnds() async throws {
        let gate = MLXInferenceGate(clock: TestClock())
        let inner = InnerStream()
        let seen = LockedArray<Int>()
        let caller = consume(gate.runStream(firstElement: .seconds(3), work: { inner.work() }), into: seen)
        inner.continuation.yield(1)
        #expect(await waitUntil { seen.values == [1] })

        caller.cancel()

        #expect(await waitUntil { await gate.isHeldByAbandonedStream })
        #expect(await gate.isBusy)
        inner.continuation.yield(2)
        inner.continuation.finish()
        #expect(await waitUntil { !(await gate.isBusy) })
        #expect(!(await gate.isHeldByAbandonedStream))
        #expect(seen.values == [1], "the abandoned caller still received elements")
        _ = try? await caller.value
    }

    @Test("the first-element limit counts from the call, so the gate wait fires first when shorter (REQ-QS-03)")
    func firstElementTimeoutCountsGateWait() async throws {
        let clock = TestClock()
        let gate = MLXInferenceGate(clock: clock)
        let hold = AsyncGate()
        let holder = Task { try await gate.run(wait: .seconds(2), inference: .seconds(10)) { await hold.wait(); return 0 } }
        #expect(await waitUntil { await gate.isBusy && clock.sleeperCount == 1 })
        let inner = InnerStream()
        let stream = gate.runStream(wait: .seconds(2), firstElement: .seconds(3), work: { inner.work() })
        let caller = consume(stream, into: LockedArray<Int>())
        #expect(await waitUntil {
            await gate.waitingCount == 1 && clock.pendingDeadlines == [.seconds(2), .seconds(3), .seconds(10)]
        })

        clock.advance(by: .seconds(2))

        await #expect(throws: QwenCloneError.gateBusy) { try await caller.value }
        #expect(inner.callCount == 0)
        hold.open()
        _ = try await holder.value
    }

    @Test("no first element in time → .inferenceTimeout, and the gate stays closed until the model ends (REQ-QS-03)")
    func firstElementTimeoutKeepsGateClosed() async throws {
        let clock = TestClock()
        let gate = MLXInferenceGate(clock: clock)
        let inner = InnerStream()
        let caller = consume(gate.runStream(firstElement: .seconds(3), work: { inner.work() }), into: LockedArray())
        #expect(await waitUntil { inner.callCount == 1 && clock.pendingDeadlines == [.seconds(3)] })

        clock.advance(by: .seconds(3))

        await #expect(throws: QwenCloneError.inferenceTimeout) { try await caller.value }
        #expect(await gate.isBusy, "the gate opened while the model was still generating")
        #expect(await gate.isHeldByAbandonedStream)
        inner.continuation.finish()
        #expect(await waitUntil { !(await gate.isBusy) })
    }

    @Test("an element that is not a first element (stream info) does not stop the first-element timer")
    func infoDoesNotStopTimer() async throws {
        let clock = TestClock()
        let gate = MLXInferenceGate(clock: clock)
        let inner = InnerStream()
        let seen = LockedArray<Int>()
        let stream = gate.runStream(firstElement: .seconds(3), isFirst: { $0 > 0 }, work: { inner.work() })
        let caller = consume(stream, into: seen)
        inner.continuation.yield(0)
        #expect(await waitUntil { seen.values == [0] && clock.pendingDeadlines == [.seconds(3)] })

        clock.advance(by: .seconds(3))

        await #expect(throws: QwenCloneError.inferenceTimeout) { try await caller.value }
        inner.continuation.finish()
        #expect(await waitUntil { !(await gate.isBusy) })
    }

    @Test("a first element stops the first-element timer")
    func firstElementStopsTimer() async throws {
        let clock = TestClock()
        let gate = MLXInferenceGate(clock: clock)
        let inner = InnerStream()
        let seen = LockedArray<Int>()
        let caller = consume(gate.runStream(firstElement: .seconds(3), work: { inner.work() }), into: seen)
        inner.continuation.yield(1)
        #expect(await waitUntil { seen.values == [1] && clock.sleeperCount == 0 })

        clock.advance(by: .seconds(3))
        inner.continuation.yield(2)
        inner.continuation.finish()

        try await caller.value
        #expect(seen.values == [1, 2])
    }

    @Test("an error from the model stream reaches the caller and the gate opens")
    func innerErrorRelayedAndReleased() async throws {
        let gate = MLXInferenceGate(clock: TestClock())
        let inner = InnerStream()
        let caller = consume(gate.runStream(firstElement: .seconds(3), work: { inner.work() }), into: LockedArray())

        inner.continuation.finish(throwing: FakeSynthError.boom)

        await #expect(throws: FakeSynthError.boom) { try await caller.value }
        #expect(!(await gate.isBusy))
    }

    @Test("waitUntilIdle waits for an abandoned stream's model to end (REQ-QS-08)")
    func waitUntilIdleWaitsForPump() async throws {
        let gate = MLXInferenceGate(clock: TestClock())
        let inner = InnerStream()
        let seen = LockedArray<Int>()
        let caller = consume(gate.runStream(firstElement: .seconds(3), work: { inner.work() }), into: seen)
        inner.continuation.yield(1)
        #expect(await waitUntil { seen.values == [1] })
        caller.cancel()
        #expect(await waitUntil { await gate.isHeldByAbandonedStream })

        let events = LockedArray<String>()
        let idle = Task {
            await gate.waitUntilIdle()
            events.append("idle")
        }
        // Negative check: idle must not return while the model is still generating.
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { !events.values.isEmpty }))
        events.append("finishing")
        inner.continuation.finish()

        await idle.value
        #expect(events.values == ["finishing", "idle"])
    }

    @Test("a one-shot inference waits for a running stream, then runs; never two at once (REQ-T-30)")
    func oneShotAndStreamExclude() async throws {
        let gate = MLXInferenceGate(clock: TestClock())
        let probe = ConcurrencyProbe()
        let inner = InnerStream()
        let seen = LockedArray<Int>()
        let stream = gate.runStream(firstElement: .seconds(3), work: {
            probe.enter()
            return inner.work()
        })
        let caller = consume(stream, into: seen)
        inner.continuation.yield(1)
        #expect(await waitUntil { seen.values == [1] })

        let oneShot = Task {
            try await gate.run(wait: .seconds(2), inference: .seconds(10)) { probe.enter(); probe.leave(); return 7 }
        }
        #expect(await waitUntil { await gate.waitingCount == 1 })
        #expect(probe.started == 1, "the one-shot started on top of the stream")

        probe.leave()
        inner.continuation.finish()

        #expect(try await oneShot.value == 7)
        try await caller.value
        #expect(probe.peak == 1)
    }

    @Test("a stream cancelled while queued leaves the queue and never calls work")
    func cancelWhileQueuedNeverStarts() async throws {
        let gate = MLXInferenceGate(clock: TestClock())
        let hold = AsyncGate()
        let holder = Task { try await gate.run(wait: .seconds(2), inference: .seconds(10)) { await hold.wait(); return 0 } }
        #expect(await waitUntil { await gate.isBusy })
        let inner = InnerStream()
        let caller = consume(gate.runStream(firstElement: .seconds(3), work: { inner.work() }), into: LockedArray())
        #expect(await waitUntil { await gate.waitingCount == 1 })

        caller.cancel()

        #expect(await waitUntil { await gate.waitingCount == 0 })
        hold.open()
        _ = try await holder.value
        // Negative check: the cancelled stream's work must never run (bounded wait, nothing to wait for).
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { inner.callCount > 0 }))
        #expect(!(await gate.isBusy))
        _ = try? await caller.value
    }

    @Test("admission refused once the gate is held: the gate opens, work never runs, the caller gets the error")
    func admissionRefusedReleasesGate() async throws {
        let gate = MLXInferenceGate(clock: TestClock())
        let inner = InnerStream()
        let stream = gate.runStream(
            firstElement: .seconds(3),
            admit: { () async throws -> Int in throw QwenCloneError.modelNotReady },
            work: { _ in inner.work() }
        )
        let caller = consume(stream, into: LockedArray())

        await #expect(throws: QwenCloneError.modelNotReady) { try await caller.value }
        #expect(inner.callCount == 0)
        #expect(await waitUntil { !(await gate.isBusy) })
    }
}
