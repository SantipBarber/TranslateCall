import AVFoundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "TTSPlaybackService")

// MARK: - TTSPlaybackLimits

/// Tunables of `TTSPlaybackService` (design §3.3); injectable so tests can shrink them.
nonisolated struct TTSPlaybackLimits: Sendable {
    /// Utterances waiting behind the one in flight (REQ-T-12).
    var maxPending = 3
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
/// `speak` enqueues (at most `maxPending` waiting, the oldest dropped) and returns. One worker runs
/// utterances strictly one at a time: it starts the synthesizer, schedules each buffer as it arrives
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

    private struct Utterance: Sendable {
        let text: String
        let locale: Locale
    }

    private enum AttemptEnd: Equatable {
        case finished
        case failed(String)
        case outputFailed
        case timedOut
        case cancelled
    }

    private enum Drain: Sendable {
        case played, stopped, stalled
    }

    private enum Outcome {
        case played
        case skipped(TTSSkipReason)
        case stale
    }

    // MARK: Dependencies

    private let primary: any UtteranceSynthesizer
    private let fallback: (any UtteranceSynthesizer)?
    private let output: any AudioOutputting
    private let limits: TTSPlaybackLimits
    private let clock: any Clock<Duration>
    private let metrics: TTSMetricsCollector

    // MARK: State

    private let speakingContinuation: AsyncStream<Bool>.Continuation
    private let eventsContinuation: AsyncStream<TTSEvent>.Continuation
    private let wakeups: AsyncStream<Void>
    private let wakeupContinuation: AsyncStream<Void>.Continuation

    private var queue: [Utterance] = []
    private var generation: UInt64 = 0
    private var isSpeaking = false
    private var isDeactivated = false
    private var worker: Task<Void, Never>?
    private var attemptTask: Task<AttemptEnd, Never>?
    private var bufferObserver: (@Sendable (AVAudioPCMBuffer) -> Void)?

    // Circuit breaker on the primary (REQ-T-23).
    private var consecutiveFailures = 0
    private(set) var isBreakerOpen = false
    private var breakerTask: Task<Void, Never>?

    // The attempt in flight. Only the worker starts attempts, one at a time.
    private var attemptStartedAt = ContinuousClock.now
    private var attemptFirstBufferAt: ContinuousClock.Instant?
    private var attemptBufferCount = 0
    private var attemptAudioSeconds: Double = 0
    private var attemptLastHandle: PlaybackHandle?

    // MARK: Init

    init(
        primary: any UtteranceSynthesizer,
        fallback: (any UtteranceSynthesizer)? = nil,
        output: any AudioOutputting,
        limits: TTSPlaybackLimits = .default,
        clock: any Clock<Duration> = ContinuousClock(),
        metrics: TTSMetricsCollector = .shared
    ) {
        self.primary = primary
        self.fallback = fallback
        self.output = output
        self.limits = limits
        self.clock = clock
        self.metrics = metrics
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
        if queue.count >= limits.maxPending {
            queue.removeFirst()
            eventsContinuation.yield(.utteranceDropped)
            logger.info("TTS queue full: dropped the oldest pending sentence")
        }
        queue.append(Utterance(text: text, locale: locale))
        if worker == nil { worker = Task { await self.runWorker() } }
        wakeupContinuation.yield()
    }

    func stopSpeaking() async {
        generation &+= 1
        queue.removeAll()
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

    // MARK: Worker

    private func runWorker() async {
        for await _ in wakeups {
            while !queue.isEmpty {
                let utterance = queue.removeFirst()
                await play(utterance)
            }
        }
    }

    private func play(_ utterance: Utterance) async {
        let gen = generation
        let outcome = await perform(utterance, gen: gen)
        guard gen == generation else { return }   // stopSpeaking already reported and cleared
        if case .skipped(let reason) = outcome {
            eventsContinuation.yield(.utteranceSkipped(reason))
            logger.warning("TTS sentence skipped: \(String(describing: reason), privacy: .public)")
        }
        if queue.isEmpty { setSpeaking(false) }
    }

    private func perform(_ utterance: Utterance, gen: UInt64) async -> Outcome {
        let fallbackReady = fallback?.canSpeak(utterance.locale) ?? false
        // The breaker only diverts when the fallback can take the sentence: with no usable
        // fallback the primary is the only voice there is, so it keeps being tried.
        guard primary.canSpeak(utterance.locale), !(isBreakerOpen && fallbackReady) else {
            guard let fallback, fallbackReady else { return .skipped(.noVoice) }
            return await speakWithFallback(fallback, utterance, gen: gen)
        }
        let end = await runAttempt(primary, utterance, gen: gen)
        let heardNothing = attemptBufferCount == 0
        switch end {
        case .finished: consecutiveFailures = 0
        case .failed, .timedOut: if heardNothing { recordPrimaryFailure() }
        case .outputFailed, .cancelled: break
        }
        if case .failed(let message) = end, heardNothing {
            guard let fallback, fallbackReady else { return .skipped(.primaryFailed(message)) }
            return await speakWithFallback(fallback, utterance, gen: gen)
        }
        return await conclude(end, engine: primary.engine, utterance: utterance, gen: gen)
    }

    /// The same utterance again, on the fallback (REQ-T-20/22). The fallback has no fallback.
    private func speakWithFallback(
        _ fallback: any UtteranceSynthesizer, _ utterance: Utterance, gen: UInt64
    ) async -> Outcome {
        eventsContinuation.yield(.fellBack(from: primary.engine, to: fallback.engine))
        let end = await runAttempt(fallback, utterance, gen: gen)
        if case .failed(let message) = end, attemptBufferCount == 0 {
            return .skipped(.primaryFailed(message))
        }
        return await conclude(end, engine: fallback.engine, utterance: utterance, gen: gen)
    }

    private func recordPrimaryFailure() {
        consecutiveFailures += 1
        guard consecutiveFailures >= limits.breakerThreshold, !isBreakerOpen else { return }
        isBreakerOpen = true
        let failures = consecutiveFailures
        logger.warning("TTS primary failed \(failures) times in a row: fallback only for the cooldown")
        let clock = self.clock
        let cooldown = limits.breakerCooldown
        breakerTask = Task { [weak self] in
            do { try await clock.sleep(for: cooldown) } catch { return }
            await self?.halfOpenBreaker()
        }
    }

    /// Cooldown over: the primary is tried again, and one more failure reopens the breaker at once.
    private func halfOpenBreaker() {
        isBreakerOpen = false
        consecutiveFailures = limits.breakerThreshold - 1
        breakerTask = nil
    }

    private func setSpeaking(_ speaking: Bool) {
        guard speaking != isSpeaking else { return }
        isSpeaking = speaking
        speakingContinuation.yield(speaking)
    }
}

// MARK: - One attempt

extension TTSPlaybackService {

    /// Runs one synthesizer on one utterance under the watchdog, scheduling each buffer it yields.
    private func runAttempt(
        _ synthesizer: any UtteranceSynthesizer, _ utterance: Utterance, gen: UInt64
    ) async -> AttemptEnd {
        guard gen == generation else { return .cancelled }
        attemptStartedAt = .now
        attemptFirstBufferAt = nil
        attemptBufferCount = 0
        attemptAudioSeconds = 0
        attemptLastHandle = nil
        setSpeaking(true)
        let stream = synthesizer.synthesize(text: utterance.text, locale: utterance.locale)
        let consumer = Task { await self.consume(stream, gen: gen) }
        attemptTask = consumer
        let watchdog = Task { [clock, limit = limits.utteranceWatchdog] in
            do { try await clock.sleep(for: limit) } catch { return false }
            consumer.cancel()
            return true
        }
        let end = await consumer.value
        watchdog.cancel()
        let timedOut = await watchdog.value
        attemptTask = nil
        return end == .cancelled && timedOut && gen == generation ? .timedOut : end
    }

    private func consume(_ stream: AsyncThrowingStream<AVAudioPCMBuffer, Error>, gen: UInt64) async -> AttemptEnd {
        do {
            for try await buffer in stream {
                guard gen == generation, !Task.isCancelled else { return .cancelled }
                guard buffer.frameLength > 0 else { continue }
                do {
                    attemptLastHandle = try output.schedule(buffer)
                } catch {
                    logger.error("TTS output refused a buffer: \(error.localizedDescription, privacy: .public)")
                    return .outputFailed
                }
                bufferObserver?(buffer)
                if attemptFirstBufferAt == nil { attemptFirstBufferAt = .now }
                attemptBufferCount += 1
                attemptAudioSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
            }
        } catch {
            guard gen == generation, !Task.isCancelled else { return .cancelled }
            return .failed(error.localizedDescription)
        }
        guard gen == generation, !Task.isCancelled else { return .cancelled }
        return .finished
    }

    /// Waits for the attempt's audio to play out, then names the outcome (REQ-T-13/16/21).
    private func conclude(_ end: AttemptEnd, engine: TTSEngine, utterance: Utterance, gen: UInt64) async -> Outcome {
        if end == .cancelled { return .stale }
        if end == .outputFailed {
            output.stop()
            return .skipped(.outputUnavailable)
        }
        switch await drainPlayback() {
        case .stopped:
            return gen == generation ? .skipped(.outputUnavailable) : .stale
        case .stalled:
            output.stop()
            return .skipped(.outputUnavailable)
        case .played:
            if end == .timedOut { return .skipped(.timeout) }
            guard end == .finished else { return .skipped(.interrupted) }
            await recordMetrics(engine: engine, utterance: utterance)
            return .played
        }
    }

    /// Waits for the attempt's last buffer to be played back, bounded by the audio's length plus
    /// `playbackGrace`, so a device that never reports back cannot keep `isSpeaking` true (REQ-T-16).
    private func drainPlayback() async -> Drain {
        guard let handle = attemptLastHandle else { return .played }
        let bound = Duration.seconds(attemptAudioSeconds) + limits.playbackGrace
        let clock = self.clock
        return await withTaskGroup(of: Drain.self) { group in
            group.addTask {
                do { try await handle.wait() } catch { return .stopped }
                return .played
            }
            group.addTask {
                do { try await clock.sleep(for: bound) } catch { return .stopped }
                return .stalled
            }
            let first = await group.next() ?? .stopped
            group.cancelAll()
            return first
        }
    }

    private func recordMetrics(engine: TTSEngine, utterance: Utterance) async {
        guard let firstBufferAt = attemptFirstBufferAt else { return }   // nothing was heard
        let latency = attemptStartedAt.duration(to: firstBufferAt)
        await metrics.record(TTSMetrics(
            engine: engine,
            synthesisLatencyMs: Int(latency / .milliseconds(1)),
            textLength: utterance.text.count,
            locale: utterance.locale,
            timestamp: Date()
        ))
    }
}
