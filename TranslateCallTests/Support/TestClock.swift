import Synchronization

/// Manual `Clock` (design §5.1): time moves only on `advance(by:)`, so watchdogs, breakers and
/// timeouts are tested without sleeping. Wait on `sleeperCount` / `pendingDeadlines` before advancing.
final class TestClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        let offset: Swift.Duration
        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: UInt64
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
        var cancelledEarly: Set<UInt64> = []
    }

    private enum Registration { case waiting, due, cancelled }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Swift.Duration { .zero }

    /// Tasks currently suspended in `sleep`.
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    /// Deadlines of the suspended sleepers, as offsets from the clock's start, earliest first.
    var pendingDeadlines: [Swift.Duration] { state.withLock { $0.sleepers.map(\.deadline.offset).sorted() } }

    func sleep(until deadline: Instant, tolerance: Swift.Duration? = nil) async throws {
        let id: UInt64 = state.withLock { current in
            current.nextID += 1
            return current.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let registration: Registration = self.state.withLock { current in
                    if current.cancelledEarly.remove(id) != nil { return .cancelled }
                    if deadline <= current.now { return .due }
                    current.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .waiting
                }
                switch registration {
                case .waiting: break
                case .due: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper: Sleeper? = self.state.withLock { current in
                if let index = current.sleepers.firstIndex(where: { $0.id == id }) {
                    return current.sleepers.remove(at: index)
                }
                current.cancelledEarly.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has been reached.
    func advance(by duration: Swift.Duration) {
        let due: [Sleeper] = state.withLock { current in
            current.now = current.now.advanced(by: duration)
            let now = current.now
            let due = current.sleepers.filter { $0.deadline <= now }
            current.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }
}
