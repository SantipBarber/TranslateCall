import Foundation
import OSLog
import Synchronization

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "MLXInferenceGate")

// MARK: - GateStreamLink

/// What the gate knows about the stream holding it: whether anyone still listens to it.
nonisolated protocol GateStreamLink: AnyObject, Sendable {
    var isAttached: Bool { get }
}

// MARK: - StreamRelay

/// The caller's side of a gated stream. Attached until it ends (the pump's end, the first-element timer,
/// a gate failure) or the consumer goes away (`detach()`), whichever comes first; after that every call
/// does nothing, so the pump can keep draining the model without anyone hearing it.
nonisolated final class StreamRelay<Element: Sendable>: GateStreamLink {
    private struct State {
        var continuation: AsyncThrowingStream<Element, Error>.Continuation?
        var hasRelayedFirst = false
    }

    private let state: Mutex<State>

    init(_ continuation: AsyncThrowingStream<Element, Error>.Continuation) {
        state = Mutex(State(continuation: continuation))
    }

    var isAttached: Bool { state.withLock { $0.continuation != nil } }

    /// Relays `element` while attached; `first` marks it as the one the first-element timer waits for.
    func yield(_ element: Element, first: Bool) {
        let continuation = state.withLock { current in
            if first, current.continuation != nil { current.hasRelayedFirst = true }
            return current.continuation
        }
        continuation?.yield(element)
    }

    /// Ends the caller's stream, once. With `onlyBeforeFirst`, does nothing if a first element went out.
    func end(throwing error: Error? = nil, onlyBeforeFirst: Bool = false) {
        let continuation = state.withLock { current -> AsyncThrowingStream<Element, Error>.Continuation? in
            if onlyBeforeFirst, current.hasRelayedFirst { return nil }
            defer { current.continuation = nil }
            return current.continuation
        }
        // Outside the lock: `finish` runs `onTermination`, which calls `detach()`.
        continuation?.finish(throwing: error)
    }

    /// The consumer went away: stop relaying without finishing anything.
    func detach() {
        state.withLock { $0.continuation = nil }
    }
}

// MARK: - MLXInferenceGate + streaming

extension MLXInferenceGate {
    /// True while a stream nobody listens to any more still holds the gate (its model has not ended).
    var isHeldByAbandonedStream: Bool {
        guard let currentStream else { return false }
        return !currentStream.isAttached
    }

    /// One streaming Qwen inference under the gate (REQ-QS-06). The returned stream relays the model's
    /// elements while the caller listens; the gate stays closed until `work`'s stream has ended, whatever
    /// the caller does, because mlx-audio's generation cannot be stopped and its stream's end is the only
    /// "model done" signal. `.gateBusy` after `wait`; `.inferenceTimeout` if no `isFirst` element went out
    /// within `firstElement` of this call (gate wait included, REQ-QS-03).
    nonisolated func runStream<Element: Sendable>(
        wait: Duration = .seconds(2),
        firstElement: Duration,
        isFirst: @escaping @Sendable (Element) -> Bool = { _ in true },
        work: @escaping @Sendable () -> AsyncThrowingStream<Element, Error>
    ) -> AsyncThrowingStream<Element, Error> {
        runStream(wait: wait, firstElement: firstElement, isFirst: isFirst, admit: {}, work: { _ in work() })
    }

    /// `runStream` with an admission step: once the gate is held, and before the model starts, `admit` runs
    /// and hands `work` what it needs (REQ-QS-08: the model's owner re-checks it is still loaded, as an unload
    /// may have slipped in while the caller queued). If `admit` throws, the gate is released and the caller's
    /// stream ends with that error; the model never starts.
    nonisolated func runStream<Admitted: Sendable, Element: Sendable>(
        wait: Duration = .seconds(2),
        firstElement: Duration,
        isFirst: @escaping @Sendable (Element) -> Bool = { _ in true },
        admit: @escaping @Sendable () async throws -> Admitted,
        work: @escaping @Sendable (Admitted) -> AsyncThrowingStream<Element, Error>
    ) -> AsyncThrowingStream<Element, Error> {
        let (stream, continuation) = AsyncThrowingStream<Element, Error>.makeStream()
        let relay = StreamRelay(continuation)
        let clock = self.clock
        let timer = Task.detached {
            do { try await clock.sleep(for: firstElement) } catch { return }
            relay.end(throwing: QwenCloneError.inferenceTimeout, onlyBeforeFirst: true)
        }
        let starter = Task { [self] in
            do {
                try await startStream(relay: relay, wait: wait, timer: timer, isFirst: isFirst) {
                    let admitted = try await admit()
                    return { work(admitted) }
                }
            } catch {
                timer.cancel()
                relay.end(throwing: error)            // nothing if the consumer or the timer ended it first
            }
        }
        // Installed after the timer and the starter exist, so the closure can cancel them. Safe: no consumer
        // holds the stream before this function returns, and if the timer or the starter ends it first, they
        // do so through `relay.end`, which detaches the relay itself; the starter's `relay.isAttached` guard
        // then sees a detached relay and releases the gate without starting the model.
        continuation.onTermination = { _ in
            relay.detach()
            starter.cancel()                          // a queued stream leaves the queue
            timer.cancel()
        }
        return stream
    }

    // MARK: Private

    /// `admit` runs once the gate is held and returns the model's work, or throws to refuse it.
    private func startStream<Element: Sendable>(
        relay: StreamRelay<Element>,
        wait: Duration,
        timer: Task<Void, Never>,
        isFirst: @escaping @Sendable (Element) -> Bool,
        admit: @escaping @Sendable () async throws -> @Sendable () -> AsyncThrowingStream<Element, Error>
    ) async throws {
        try await acquire(waitLimit: wait)
        let work: @Sendable () -> AsyncThrowingStream<Element, Error>
        do {
            work = try await admit()                  // with the gate held: nothing can unload under the model
        } catch {
            release()
            throw error                               // the starter ends the caller's stream with it
        }
        guard relay.isAttached else {                 // ended while being handed the gate: never start MLX
            release()
            timer.cancel()
            return
        }
        currentStream = relay
        let heldSince = ContinuousClock.now
        // Detached: the pump must not inherit any caller's executor or cancellation; it always drains.
        Task.detached { [self] in
            await pump(relay: relay, heldSince: heldSince, timer: timer, isFirst: isFirst, work: work)
        }
    }

    private nonisolated func pump<Element: Sendable>(
        relay: StreamRelay<Element>,
        heldSince: ContinuousClock.Instant,
        timer: Task<Void, Never>,
        isFirst: @Sendable (Element) -> Bool,
        work: @Sendable () -> AsyncThrowingStream<Element, Error>
    ) async {
        var failure: Error?
        do {
            for try await element in work() {
                let first = isFirst(element)
                relay.yield(element, first: first)
                if first { timer.cancel() }
            }
        } catch {
            failure = error
        }
        timer.cancel()
        if !relay.isAttached {                        // nobody listened any more: log how long it held the gate
            let heldMs = Int(((ContinuousClock.now - heldSince).secondsValue * 1_000).rounded())
            logger.info("Abandoned voice clone stream drained; it held the gate heldMs=\(heldMs, privacy: .public)")
        }
        // Release before ending the relay: a caller that saw the end finds the gate open, and the gate is
        // never "held by an abandoned stream" just because the pump itself ended the relay.
        await release()
        relay.end(throwing: failure)
    }
}
