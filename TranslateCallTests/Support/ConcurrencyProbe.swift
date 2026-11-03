import Synchronization

/// Counts how many gated "inferences" run at once.
final class ConcurrencyProbe: Sendable {
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
