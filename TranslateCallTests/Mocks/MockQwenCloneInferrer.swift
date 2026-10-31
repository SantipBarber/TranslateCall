import Foundation
import Synchronization
@testable import TranslateCall

// MARK: - MockQwenCloneInferrer

/// Test mock for `QwenCloneInferring`. Tracks calls and returns configurable stubs.
actor MockQwenCloneInferrer: QwenCloneInferring {

    nonisolated let sampleRate: Int = 24_000

    // MARK: - Stubs

    private var stubSamples: [Float] = Array(repeating: 0.1, count: 2400)
    private var stubError: Error?
    private var stubDelay: Duration?

    /// Opens the `holdBefore` pause of a stub stream.
    nonisolated let gate = AsyncGate()

    private struct StreamStub {
        var events: [QwenStreamEvent]?
        var holdBefore: Int?
        var failAfter: Int?
        var callCount = 0
    }

    private nonisolated let streamStub = Mutex(StreamStub())

    nonisolated var streamCallCount: Int { streamStub.withLock { $0.callCount } }

    // MARK: - Tracking

    private(set) var callCount: Int = 0
    private(set) var lastText: String?
    private(set) var lastLanguage: String?
    private(set) var lastReferenceAudioCount: Int = 0

    // MARK: - Configuration

    func setStubSamples(_ samples: [Float]) {
        stubSamples = samples
    }

    func setStubError(_ error: Error?) {
        stubError = error
    }

    func setStubDelay(_ delay: Duration?) {
        stubDelay = delay
    }

    /// `synthesizeStream` yields `events`; it waits on `gate` before event `holdBefore` and throws
    /// `CancellationError` after `failAfter` events.
    func setStubStream(_ events: [QwenStreamEvent], holdBefore: Int? = nil, failAfter: Int? = nil) {
        streamStub.withLock {
            $0.events = events
            $0.holdBefore = holdBefore
            $0.failAfter = failAfter
        }
    }

    // MARK: - QwenCloneInferring

    nonisolated func synthesizeStream(
        text: String,
        referenceAudio: [Float],
        referenceTranscript: String,
        language: String
    ) -> AsyncThrowingStream<QwenStreamEvent, Error> {
        let stub = streamStub.withLock { current -> StreamStub in
            current.callCount += 1
            return current
        }
        let events = stub.events ?? [.audio(Array(repeating: 0.1, count: 2400))]
        let hold = gate
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: QwenStreamEvent.self)
        // Not cancelled on termination: like the real model, it runs to its end once started.
        Task {
            for (index, event) in events.enumerated() {
                if index == stub.holdBefore { await hold.wait() }
                if index == stub.failAfter {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                continuation.yield(event)
            }
            continuation.finish()
        }
        return stream
    }

    func synthesize(
        text: String,
        referenceAudio: [Float],
        referenceTranscript: String,
        language: String
    ) async throws -> [Float] {
        callCount += 1
        lastText = text
        lastLanguage = language
        lastReferenceAudioCount = referenceAudio.count

        if let delay = stubDelay {
            try await Task.sleep(for: delay)
        }

        if let error = stubError {
            throw error
        }

        return stubSamples
    }
}
