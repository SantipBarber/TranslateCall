import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "TTSPlaybackService")

// MARK: - Worker

extension TTSPlaybackService {

    func runWorker() async {
        for await _ in wakeups {
            while !queue.isEmpty {
                await play(takeNext())
            }
        }
    }

    /// The next utterance: the oldest pending sentence plus the following ones of the same locale,
    /// joined by a space, while the text stays within `maxCoalescedCharacters` (REQ-Q-02).
    private func takeNext() -> Utterance {
        var next = queue.removeFirst()
        while let following = queue.first, following.locale == next.locale,
              next.text.count + 1 + following.text.count <= coalescingLimit {
            next = Utterance(text: next.text + " " + following.text, locale: next.locale)
            queue.removeFirst()
        }
        if queue.count < limits.backlogNoticeThreshold { backlogNoticed = false }
        return next
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
        let (end, record) = await runAttempt(primary, utterance, gen: gen)
        let heardNothing = record.bufferCount == 0
        switch end {
        case .finished: consecutiveFailures = 0
        case .failed, .timedOut: if heardNothing, record.countsTowardBreaker { recordPrimaryFailure() }
        case .outputFailed, .cancelled: break
        }
        if case .failed(let message) = end, heardNothing {
            guard let fallback, fallbackReady else { return .skipped(.primaryFailed(message)) }
            return await speakWithFallback(fallback, utterance, gen: gen)
        }
        return await conclude(end, record: record, engine: primary.engine, utterance: utterance, gen: gen)
    }

    /// The same utterance again, on the fallback (REQ-T-20/22). The fallback has no fallback.
    private func speakWithFallback(
        _ fallback: any UtteranceSynthesizer, _ utterance: Utterance, gen: UInt64
    ) async -> Outcome {
        // A stopSpeaking() that landed while the primary attempt was awaited must not leave a
        // spurious "fell back" notice behind: stop already reported and cleared this utterance.
        guard gen == generation else { return .stale }
        eventsContinuation.yield(.fellBack(from: primary.engine, to: fallback.engine))
        let (end, record) = await runAttempt(fallback, utterance, gen: gen)
        if case .failed(let message) = end, record.bufferCount == 0 {
            return .skipped(.primaryFailed(message))
        }
        return await conclude(end, record: record, engine: fallback.engine, utterance: utterance, gen: gen)
    }

    // MARK: Circuit breaker (REQ-T-23)

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
}
