import Foundation

// MARK: - Event loop helpers

enum RehearsalEvent {
    case hostStarting
    case snapshot(RehearsalSnapshot)
    case sample(LevelSample)
    case timer(RehearsalJudge.Timer, token: Int)
}

/// The end rule over one run (REQ-FR-53/54), free of tasks so the loop stays small. Only the
/// first outgoing entry counts; it is done when it has a translation and nothing is translating
/// or speaking for 1.5 s, and the BlackHole listener heard −70 dBFS for 200 ms meanwhile.
struct RehearsalJudge {
    enum Timer: Hashable { case preparing, transcript, completion, settle }

    struct Step {
        var display: RehearsalState?
        var start: [(timer: Timer, after: Duration)] = []
        var cancel: [Timer] = []
        var verdict: RehearsalState?
    }

    static let preparingCap = Duration.seconds(90)
    static let transcriptTimeout = Duration.seconds(15)
    static let completionTimeout = Duration.seconds(30)
    static let settleTime = Duration.milliseconds(1500)

    private var capturing = false
    private var entry: TranscriptEntry?
    private var settling = false
    private var heard = false
    private var detector = SustainedLevelDetector(threshold: -70, minDuration: .milliseconds(200))

    mutating func feed(_ snapshot: RehearsalSnapshot) -> Step {
        if let error = snapshot.error { return Step(verdict: .failed(.pipeline(error))) }
        var step = Step()
        if !capturing {
            guard snapshot.isCapturing else { return step }
            capturing = true   // the timers start here, not at "Rehearse"
            step.display = .listening
            step.cancel = [.preparing]
            step.start = [(.transcript, Self.transcriptTimeout), (.completion, Self.completionTimeout)]
        }
        guard let current = snapshot.firstOutgoing else { return step }
        if let entry {
            guard current.id == entry.id else { return step }   // a later sentence: ignored
        } else {
            step.display = .translating(said: current.original)
            step.cancel.append(.transcript)
        }
        entry = current
        let delivered = current.translation != nil && !snapshot.isTranslating && !snapshot.isSpeaking
        if delivered, !settling {
            settling = true
            step.start.append((.settle, Self.settleTime))
        } else if !delivered, settling {
            settling = false
            step.cancel.append(.settle)
        }
        return step
    }

    mutating func feed(_ sample: LevelSample) {
        if capturing, detector.feed(sample) { heard = true }
    }

    func fire(_ timer: Timer) -> RehearsalState? {
        switch timer {
        case .preparing: return capturing ? nil : .failed(.preparingTooLong)
        case .transcript: return entry == nil ? .failed(.notHeard) : nil
        case .completion: return .failed(.notReceived)
        case .settle:
            guard settling, let entry, let translation = entry.translation else { return nil }
            return heard ? .passed(said: entry.original, received: translation) : .failed(.notReceived)
        }
    }
}

/// One-shot timers on the injected clock; each firing carries a token so a stale one is dropped.
@MainActor
final class RehearsalTimers {
    private let clock: any Clock<Duration>
    private let sink: AsyncStream<RehearsalEvent>.Continuation
    private var running: [RehearsalJudge.Timer: (token: Int, task: Task<Void, Never>)] = [:]
    private var lastToken = 0

    init(clock: any Clock<Duration>, sink: AsyncStream<RehearsalEvent>.Continuation) {
        self.clock = clock
        self.sink = sink
    }

    func start(_ timer: RehearsalJudge.Timer, after duration: Duration) {
        cancel(timer)
        lastToken += 1
        let token = lastToken
        let clock = clock, sink = sink
        let task = Task {
            if (try? await clock.sleep(for: duration)) != nil { sink.yield(.timer(timer, token: token)) }
        }
        running[timer] = (token, task)
    }

    func cancel(_ timer: RehearsalJudge.Timer) {
        running.removeValue(forKey: timer)?.task.cancel()
    }

    func isCurrent(_ timer: RehearsalJudge.Timer, token: Int) -> Bool {
        running[timer]?.token == token
    }

    func cancelAll() {
        running.values.forEach { $0.task.cancel() }
        running.removeAll()
    }
}
