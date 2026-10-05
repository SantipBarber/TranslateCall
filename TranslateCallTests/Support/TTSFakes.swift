import AVFoundation
import Synchronization
@testable import TranslateCall

// MARK: - AsyncGate

/// Suspends callers of `wait()` until `open()`; once open, later waits return at once.
final class AsyncGate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var waiterCount: Int { state.withLock { $0.waiters.count } }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = state.withLock { current in
                if current.isOpen { return true }
                current.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { current in
            current.isOpen = true
            defer { current.waiters.removeAll() }
            return current.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

// MARK: - LockedArray

/// Thread-safe append-only list for `@Sendable` callbacks in tests.
final class LockedArray<Element: Sendable>: Sendable {
    private let storage = Mutex<[Element]>([])

    var values: [Element] { storage.withLock { $0 } }

    func append(_ element: Element) { storage.withLock { $0.append(element) } }
}

// MARK: - StreamRecorder

/// Collects everything an `AsyncStream` emits, with arrival times, until it finishes.
final class StreamRecorder<Element: Sendable>: Sendable {
    struct Item: Sendable {
        let value: Element
        let at: ContinuousClock.Instant
    }

    private let items = Mutex<[Item]>([])
    private let finished = Mutex(false)

    init(_ stream: AsyncStream<Element>) {
        Task { [self] in
            for await value in stream {
                items.withLock { $0.append(Item(value: value, at: .now)) }
            }
            finished.withLock { $0 = true }
        }
    }

    var values: [Element] { items.withLock { $0.map(\.value) } }
    var timed: [Item] { items.withLock { $0 } }
    var isFinished: Bool { finished.withLock { $0 } }
}

// MARK: - collect

/// Every buffer of one utterance stream, or nil if it did not finish within `timeout`.
func collect(_ stream: AsyncThrowingStream<AVAudioPCMBuffer, Error>,
             within timeout: Duration = .seconds(10)) async throws -> [AVAudioPCMBuffer]? {
    try await withThrowingTaskGroup(of: [AVAudioPCMBuffer]?.self) { group in
        group.addTask {
            var buffers: [AVAudioPCMBuffer] = []
            for try await buffer in stream { buffers.append(buffer) }
            return buffers
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        defer { group.cancelAll() }
        return try await group.next() ?? nil
    }
}

// MARK: - FakeSynthesizer

enum FakeSynthError: Error, Equatable {
    case boom
}

/// Scripted `UtteranceSynthesizer` (design §5.1). Each `synthesize` call uses the next script
/// (the last one repeats) and records the text, cancellations, completions and shutdowns.
final class FakeSynthesizer: UtteranceSynthesizer, Sendable {
    struct Script: Sendable {
        var buffers: [AVAudioPCMBuffer] = [makePCMBuffer(frames: 1_600, fill: 0.5)]
        /// Throw `FakeSynthError.boom` after yielding this many buffers (nil = never).
        var failAfter: Int? = nil
        /// After the buffers, never finish (until the consumer goes away).
        var hang = false
        /// Before yielding the buffer at this index, wait for `gate.open()`.
        var holdBefore: Int? = nil
    }

    private struct Record {
        var scripts: [Script]
        var texts: [String] = []
        var cancelledCount = 0
        var completedCount = 0
        var shutdownCount = 0
    }

    let engine: TTSEngine
    let maxTextLength: Int
    let gate = AsyncGate()
    private let speakable: @Sendable (Locale) -> Bool
    private let record: Mutex<Record>

    init(engine: TTSEngine = .avSpeech,
         canSpeak: @escaping @Sendable (Locale) -> Bool = { _ in true },
         maxTextLength: Int = .max,
         scripts: [Script] = [Script()]) {
        self.engine = engine
        self.maxTextLength = maxTextLength
        speakable = canSpeak
        record = Mutex(Record(scripts: scripts))
    }

    var texts: [String] { record.withLock { $0.texts } }
    var cancelledCount: Int { record.withLock { $0.cancelledCount } }
    var completedCount: Int { record.withLock { $0.completedCount } }
    var shutdownCount: Int { record.withLock { $0.shutdownCount } }

    func canSpeak(_ locale: Locale) -> Bool { speakable(locale) }

    func synthesize(text: String, locale: Locale) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let script: Script = record.withLock { current in
            current.texts.append(text)
            let next = current.scripts.first ?? Script()
            if current.scripts.count > 1 { current.scripts.removeFirst() }
            return next
        }
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: AVAudioPCMBuffer.self, throwing: Error.self, bufferingPolicy: .unbounded
        )
        let producer = Task { [gate] in
            for (index, buffer) in script.buffers.enumerated() {
                if script.failAfter == index {
                    continuation.finish(throwing: FakeSynthError.boom)
                    return
                }
                if script.holdBefore == index { await gate.wait() }
                continuation.yield(buffer)
            }
            if script.failAfter == script.buffers.count {
                continuation.finish(throwing: FakeSynthError.boom)
                return
            }
            if script.hang {
                await Self.waitUntilCancelled()
                return
            }
            self.record.withLock { $0.completedCount += 1 }
            continuation.finish()
        }
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination { self?.record.withLock { $0.cancelledCount += 1 } }
            producer.cancel()
        }
        return stream
    }

    func shutdown() async { record.withLock { $0.shutdownCount += 1 } }

    private static func waitUntilCancelled() async {
        let (never, keepAlive) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        for await _ in never {}
        withExtendedLifetime(keepAlive) {}
    }
}

// MARK: - FakeOutput

/// Recording `AudioOutputting` (design §5.1). Handles complete when the test says so
/// (`completeAll`, `complete(index:)`), or at once with `autoComplete`.
final class FakeOutput: AudioOutputting, Sendable {
    private struct State {
        var scheduled: [AVAudioPCMBuffer] = []
        var handles: [PlaybackHandle] = []
        var stopCount = 0
        var shutdownCount = 0
        var scheduleError: Error?
    }

    private let state = Mutex(State())
    private let autoComplete: Bool

    init(autoComplete: Bool = false) {
        self.autoComplete = autoComplete
    }

    var scheduled: [AVAudioPCMBuffer] { state.withLock { $0.scheduled } }
    var scheduledCount: Int { state.withLock { $0.scheduled.count } }
    var stopCount: Int { state.withLock { $0.stopCount } }
    var shutdownCount: Int { state.withLock { $0.shutdownCount } }

    /// Every later `schedule` throws `error`; nil restores normal behaviour.
    func failSchedules(with error: Error?) { state.withLock { $0.scheduleError = error } }

    func schedule(_ buffer: AVAudioPCMBuffer) throws -> PlaybackHandle {
        let handle = PlaybackHandle()
        try state.withLock { current in
            if let error = current.scheduleError { throw error }
            current.scheduled.append(buffer)
            current.handles.append(handle)
        }
        if autoComplete { handle.markPlayed() }
        return handle
    }

    func completeAll() { state.withLock { $0.handles }.forEach { $0.markPlayed() } }

    func complete(index: Int) { state.withLock { $0.handles[index] }.markPlayed() }

    func stop() {
        let handles: [PlaybackHandle] = state.withLock { current in
            current.stopCount += 1
            return current.handles
        }
        handles.forEach { $0.markCancelled() }
    }

    func shutdown() {
        let handles: [PlaybackHandle] = state.withLock { current in
            current.shutdownCount += 1
            return current.handles
        }
        handles.forEach { $0.markCancelled() }
    }
}
