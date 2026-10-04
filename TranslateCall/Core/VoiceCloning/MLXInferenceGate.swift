import Foundation
import Synchronization

// MARK: - MLXInferenceGate

/// Runs at most one Qwen3-TTS (MLX) inference at a time, process-wide, for session TTS and the voice
/// preview alike (F8.5.2 REQ-T-30/32, backlog T6: overlapping MLX inferences crash the process).
///
/// A caller waits at most `wait` for the gate (then `QwenCloneError.gateBusy`). The inference runs in a
/// task the gate owns, so cancelling the caller never cancels MLX mid-computation; if it takes longer
/// than `inference`, the caller gets `QwenCloneError.inferenceTimeout` while the gate stays closed until
/// the inference really returns. Its late result is discarded.
actor MLXInferenceGate {
    static let shared = MLXInferenceGate()

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let clock: any Clock<Duration>
    private var busy = false
    private var waiters: [Waiter] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextWaiterID: UInt64 = 0

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    var isBusy: Bool { busy }
    var waitingCount: Int { waiters.count }

    func run<T: Sendable>(
        wait: Duration = .seconds(2),
        inference: Duration,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(waitLimit: wait)
        if Task.isCancelled {                 // cancelled while being handed the gate: never start MLX
            release()
            throw CancellationError()
        }
        let delivery = GateDelivery<T>()
        // Detached: the inference must not run on (or be cancelled with) any caller's executor.
        Task.detached { [weak self] in
            let result: Result<T, Error>
            do { result = .success(try await work()) } catch { result = .failure(error) }
            delivery.deliver(result)       // ignored if the caller already timed out
            await self?.release()
        }
        let clock = self.clock
        let timer = Task.detached {
            do { try await clock.sleep(for: inference) } catch { return }
            delivery.deliver(.failure(QwenCloneError.inferenceTimeout))
        }
        defer { timer.cancel() }
        return try await delivery.value()
    }

    /// Returns once no inference is running (`QwenCloneModelManager.unload()` waits on this).
    func waitUntilIdle() async {
        guard busy else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: Private

    private func acquire(waitLimit: Duration) async throws {
        guard busy else {
            busy = true
            return
        }
        nextWaiterID &+= 1
        let id = nextWaiterID
        let clock = self.clock
        let timer = Task { [weak self] in
            do { try await clock.sleep(for: waitLimit) } catch { return }
            await self?.expireWaiter(id)
        }
        defer { timer.cancel() }
        // Resumed by `release()` (the gate is handed over, still busy) or by `expireWaiter` (gateBusy).
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Removing the waiter from the queue is the once-only guard: whoever removes it resumes it.
    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func expireWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: QwenCloneError.gateBusy)
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
            let idle = idleWaiters
            idleWaiters.removeAll()
            idle.forEach { $0.resume() }
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}

// MARK: - GateDelivery

/// One-shot hand-off from the inference (or its timeout) to the waiting caller. The first delivery wins.
nonisolated final class GateDelivery<T: Sendable>: Sendable {
    private struct State {
        var result: Result<T, Error>?
        var waiter: CheckedContinuation<T, Error>?
        var isDelivered = false
    }

    private let state = Mutex(State())

    func deliver(_ result: Result<T, Error>) {
        let waiter: CheckedContinuation<T, Error>? = state.withLock { current in
            guard !current.isDelivered else { return nil }
            current.isDelivered = true
            if let waiting = current.waiter {
                current.waiter = nil
                return waiting
            }
            current.result = result
            return nil
        }
        waiter?.resume(with: result)
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let ready: Result<T, Error>? = state.withLock { current in
                if let result = current.result {
                    current.result = nil
                    return result
                }
                current.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}
