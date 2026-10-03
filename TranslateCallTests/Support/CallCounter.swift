import Synchronization

/// Thread-safe counter for asserting how often a `@Sendable` factory/closure ran.
final class CallCounter: Sendable {
    private let storage = Mutex(0)

    var value: Int { storage.withLock { $0 } }

    func increment() { storage.withLock { $0 += 1 } }
}
