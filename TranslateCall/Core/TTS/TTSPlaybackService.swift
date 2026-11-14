import AVFoundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "TTSPlaybackService")

// MARK: - TTSPlaybackLimits

/// Tunables of `TTSPlaybackService` (design §3.3); injectable so tests can shrink them.
nonisolated struct TTSPlaybackLimits: Sendable {
    /// Pending sentences at which one `.backlog` event is emitted (F8.5.3 REQ-Q-03). Nothing is ever dropped.
    var backlogNoticeThreshold = 20
    /// Longest text one coalesced utterance may have (F8.5.3 REQ-Q-02); 0 disables coalescing.
    var maxCoalescedCharacters = 400
    /// Longest one synthesizer may take to finish one utterance (REQ-T-16).
    var utteranceWatchdog: Duration = .seconds(30)
    /// Consecutive primary failures after which utterances go straight to the fallback (REQ-T-23).
    var breakerThreshold = 3
    var breakerCooldown: Duration = .seconds(30)
    /// Allowed on top of the scheduled audio's own length for the output to report it played (REQ-T-16).
    var playbackGrace: Duration = .seconds(5)

    static let `default` = TTSPlaybackLimits()
}

// MARK: - TTSPlaybackService

/// The one `SynthesisService` the coordinator gets, whatever the engine (F8.5.2 REQ-T-10…19).
///
/// `speak` enqueues and returns; nothing is ever dropped (F8.5.3 REQ-Q-01). One worker runs
/// utterances strictly one at a time, coalescing the sentences that queued up meanwhile into one
/// utterance to catch up (REQ-Q-02): it starts the synthesizer, schedules each buffer as it arrives
/// and waits only for the last one to be played back. `stopSpeaking` bumps `generation`, so nothing
/// synthesized before it is ever scheduled. `isSpeakingStream` is truthful: `false` only once the
/// last queued audio has been heard, or at once on stop.
actor TTSPlaybackService: SynthesisService {

    // MARK: Public streams

    nonisolated let isSpeakingStream: AsyncStream<Bool>
    nonisolated let events: AsyncStream<TTSEvent>
    nonisolated var ttsEvents: AsyncStream<TTSEvent>? { events }
    nonisolated let primaryEngine: TTSEngine
    nonisolated let fallbackEngine: TTSEngine?

    // MARK: Types

    struct Utterance: Sendable {
        let text: String
        let locale: Locale
    }

    enum AttemptEnd: Equatable {
        case finished
        case failed(String)
        case outputFailed
        case timedOut
        case cancelled
    }

    enum Drain: Sendable {
        case played, stopped, stalled
    }

    enum Outcome {
        case played
        case skipped(TTSSkipReason)
        case stale
    }

    /// What one attempt did. Only the synthesizing attempt writes `attempt`; `runAttempt` returns
    /// its final copy, so the utterance's drain and outcome read a value nothing else touches.
    struct AttemptRecord: Sendable {
        var startedAt: ContinuousClock.Instant
        var firstBufferAt: ContinuousClock.Instant?
        var bufferCount = 0
        var audioSeconds: Double = 0
        var lastHandle: PlaybackHandle?
        var countsTowardBreaker = true
    }

    // MARK: Dependencies

    let primary: any UtteranceSynthesizer
    /// Coalescing stops at the smaller of the configured limit and what the primary speaks uncut.
    let coalescingLimit: Int
    let fallback: (any UtteranceSynthesizer)?
    let output: any AudioOutputting
    let limits: TTSPlaybackLimits
    let clock: any Clock<Duration>
    let metrics: TTSMetricsCollector
    let now: @Sendable () -> ContinuousClock.Instant

    // MARK: State

    private let speakingContinuation: AsyncStream<Bool>.Continuation
    let eventsContinuation: AsyncStream<TTSEvent>.Continuation
    let wakeups: AsyncStream<Void>
    private let wakeupContinuation: AsyncStream<Void>.Continuation

    var queue: [Utterance] = []
    /// `.backlog` was reported and the queue has not fallen below the threshold since (REQ-Q-03).
    var backlogNoticed = false
    var generation: UInt64 = 0
    private var isSpeaking = false
    private var isDeactivated = false
    private var worker: Task<Void, Never>?
    var attemptTask: Task<AttemptEnd, Never>?
    var bufferObserver: (@Sendable (AVAudioPCMBuffer) -> Void)?

    // Circuit breaker on the primary (REQ-T-23).
    var consecutiveFailures = 0
    var isBreakerOpen = false
    var breakerTask: Task<Void, Never>?

    /// The attempt in flight. Only the worker starts attempts, one at a time.
    var attempt: AttemptRecord

    // MARK: Init

    init(
        primary: any UtteranceSynthesizer,
        fallback: (any UtteranceSynthesizer)? = nil,
        output: any AudioOutputting,
        limits: TTSPlaybackLimits = .default,
        clock: any Clock<Duration> = ContinuousClock(),
        metrics: TTSMetricsCollector = .shared,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.primary = primary
        coalescingLimit = min(limits.maxCoalescedCharacters, primary.maxTextLength)
        self.fallback = fallback
        self.output = output
        self.limits = limits
        self.clock = clock
        self.metrics = metrics
        self.now = now
        attempt = AttemptRecord(startedAt: now())
        primaryEngine = primary.engine
        fallbackEngine = fallback?.engine
        (isSpeakingStream, speakingContinuation) = AsyncStream.makeStream(
            of: Bool.self, bufferingPolicy: .bufferingNewest(8)
        )
        (events, eventsContinuation) = AsyncStream.makeStream(of: TTSEvent.self, bufferingPolicy: .bufferingNewest(16))
        (wakeups, wakeupContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Utterances waiting behind the one in flight.
    var pendingCount: Int { queue.count }

    // MARK: SynthesisService

    func speak(text: String, locale: Locale) async {
        guard !isDeactivated, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        queue.append(Utterance(text: text, locale: locale))
        if queue.count >= limits.backlogNoticeThreshold, !backlogNoticed {
            backlogNoticed = true
            eventsContinuation.yield(.backlog(pending: queue.count))
            logger.info("TTS backlog: \(self.queue.count) sentences waiting")
        }
        if worker == nil { worker = Task { await self.runWorker() } }
        wakeupContinuation.yield()
    }

    func stopSpeaking() async {
        generation &+= 1
        queue.removeAll()
        backlogNoticed = false
        attemptTask?.cancel()
        output.stop()
        setSpeaking(false)
    }

    func deactivate() async {
        guard !isDeactivated else { return }
        isDeactivated = true
        await stopSpeaking()
        breakerTask?.cancel()
        output.shutdown()
        await primary.shutdown()
        await fallback?.shutdown()
        wakeupContinuation.finish()
        speakingContinuation.finish()
        eventsContinuation.finish()
    }

    func setAudioMonitor(_ monitor: TTSAudioMonitor?) async {
        guard let monitor else {
            bufferObserver = nil
            return
        }
        bufferObserver = { buffer in monitor.process(buffer) }
    }

    /// Receives every buffer right after it is scheduled (`setAudioMonitor` installs the monitor here).
    func setBufferObserver(_ observer: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        bufferObserver = observer
    }

    func setSpeaking(_ speaking: Bool) {
        guard speaking != isSpeaking else { return }
        isSpeaking = speaking
        speakingContinuation.yield(speaking)
    }
}
