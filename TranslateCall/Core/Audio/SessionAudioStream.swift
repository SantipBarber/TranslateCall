import AVFoundation
import os
import Synchronization

nonisolated private let logger = Logger(subsystem: "TranslateCall", category: "SessionAudioStream")

/// One capture session's 16 kHz stream (F8.5.1 REQ-C-01/05): bounded, drop-counting, finish-once.
///
/// The producer owns it: create one per capture session, `yield` from the audio callback,
/// `finish()` when the session ends. `yield` never blocks or hops actors, so it is safe on
/// AVAudioEngine tap and SCStream sample-handler threads (NFR-C-03).
nonisolated final class SessionAudioStream: Sendable {
    static let capacity = 64

    let stream: AsyncStream<AVAudioPCMBuffer>
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private let label: String
    private let dropped = Atomic<Int>(0)
    private let lastReportNanos = Atomic<UInt64>(0)

    init(label: String, capacity: Int = SessionAudioStream.capacity) {
        self.label = label
        (stream, continuation) = AsyncStream.makeStream(
            of: AVAudioPCMBuffer.self, bufferingPolicy: .bufferingNewest(capacity)
        )
    }

    var droppedCount: Int { dropped.load(ordering: .relaxed) }

    func yield(_ buffer: AVAudioPCMBuffer) {
        guard case .dropped = continuation.yield(buffer) else { return }
        let total = dropped.add(1, ordering: .relaxed).newValue
        let now = DispatchTime.now().uptimeNanoseconds
        let last = lastReportNanos.load(ordering: .relaxed)
        guard now &- last >= 1_000_000_000,
              lastReportNanos.compareExchange(expected: last, desired: now, ordering: .relaxed).exchanged
        else { return }
        logger.warning("\(self.label, privacy: .public): consumer too slow — \(total) buffers dropped so far")
    }

    func finish() {
        continuation.finish()
    }
}
