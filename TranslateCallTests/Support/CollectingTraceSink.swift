import Synchronization
@testable import TranslateCall

/// Keeps every trace event in order (unit tests, and the bench run's sink).
final class CollectingTraceSink: TraceSink {
    private let stored = Mutex<[TraceEvent]>([])

    var events: [TraceEvent] { stored.withLock { $0 } }

    func record(_ event: TraceEvent) { stored.withLock { $0.append(event) } }

    /// Stages of `seq` in arrival order.
    func stages(of seq: Int) -> [TraceStage] { events.filter { $0.seq == seq }.map(\.stage) }

    func event(_ seq: Int, _ stage: TraceStage) -> TraceEvent? {
        events.first { $0.seq == seq && $0.stage == stage }
    }
}
