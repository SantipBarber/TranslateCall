import AVFoundation
import Synchronization

// MARK: - AudioOutputting

/// Where `TTSPlaybackService` sends PCM (design §3.2). `TTSOutput` is the device implementation;
/// tests use `FakeOutput`.
nonisolated protocol AudioOutputting: AnyObject, Sendable {
    /// Schedules a buffer. The handle completes when the buffer has been played back
    /// (`.dataPlayedBack`) or is cancelled by `stop()`, `shutdown()` or a lost device.
    func schedule(_ buffer: AVAudioPCMBuffer) throws -> PlaybackHandle
    /// Cancels everything scheduled.
    func stop()
    /// `stop()` and release the device.
    func shutdown()
}

// MARK: - PlaybackHandle

/// Completion of one scheduled buffer, resolved exactly once: played back, or cancelled.
/// The first resolution wins.
nonisolated final class PlaybackHandle: Sendable {
    private enum Resolution { case played, cancelled }

    private struct State {
        var resolution: Resolution?
        var waiters: [UInt64: CheckedContinuation<Void, Error>] = [:]
        var abandoned: Set<UInt64> = []
        var nextWaiterID: UInt64 = 0
    }

    private let state = Mutex(State())

    init() {}

    var isResolved: Bool { state.withLock { $0.resolution != nil } }
    var isPlayed: Bool { state.withLock { $0.resolution == .played } }

    func markPlayed() { resolve(.played) }
    func markCancelled() { resolve(.cancelled) }

    /// Returns once the buffer has played back. Throws `CancellationError` when the handle was
    /// cancelled, or when the waiting task is cancelled (the handle itself then stays unresolved).
    func wait() async throws {
        let waiterID: UInt64 = state.withLock { current in
            current.nextWaiterID += 1
            return current.nextWaiterID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let known: Resolution? = self.state.withLock { current in
                    if let resolution = current.resolution { return resolution }
                    if current.abandoned.remove(waiterID) != nil { return .cancelled }
                    current.waiters[waiterID] = continuation
                    return nil
                }
                switch known {
                case .played?: continuation.resume()
                case .cancelled?: continuation.resume(throwing: CancellationError())
                case nil: break
                }
            }
        } onCancel: {
            let waiting: CheckedContinuation<Void, Error>? = self.state.withLock { current in
                if let continuation = current.waiters.removeValue(forKey: waiterID) { return continuation }
                if current.resolution == nil { current.abandoned.insert(waiterID) }
                return nil
            }
            waiting?.resume(throwing: CancellationError())
        }
    }

    private func resolve(_ resolution: Resolution) {
        let waiters: [CheckedContinuation<Void, Error>] = state.withLock { current in
            guard current.resolution == nil else { return [] }
            current.resolution = resolution
            defer { current.waiters.removeAll() }
            return Array(current.waiters.values)
        }
        for waiter in waiters {
            if resolution == .played {
                waiter.resume()
            } else {
                waiter.resume(throwing: CancellationError())
            }
        }
    }
}
