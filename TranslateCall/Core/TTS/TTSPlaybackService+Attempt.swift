import AVFoundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "TTSPlaybackService")

// MARK: - One attempt

extension TTSPlaybackService {

    /// Runs one synthesizer on one utterance under the watchdog, scheduling each buffer it yields.
    func runAttempt(
        _ synthesizer: any UtteranceSynthesizer, _ utterance: Utterance, gen: UInt64
    ) async -> (end: AttemptEnd, record: AttemptRecord) {
        guard gen == generation else { return (.cancelled, AttemptRecord(startedAt: now())) }
        attempt = AttemptRecord(startedAt: now())
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
        return (end == .cancelled && timedOut && gen == generation ? .timedOut : end, attempt)
    }

    private func consume(_ stream: AsyncThrowingStream<AVAudioPCMBuffer, Error>, gen: UInt64) async -> AttemptEnd {
        do {
            for try await buffer in stream {
                guard gen == generation, !Task.isCancelled else { return .cancelled }
                guard buffer.frameLength > 0 else { continue }
                do {
                    attempt.lastHandle = try output.schedule(buffer)
                } catch {
                    logger.error("TTS output refused a buffer: \(error.localizedDescription, privacy: .public)")
                    return .outputFailed
                }
                bufferObserver?(buffer)
                if attempt.firstBufferAt == nil { attempt.firstBufferAt = now() }
                attempt.bufferCount += 1
                attempt.audioSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
            }
        } catch {
            guard gen == generation, !Task.isCancelled else { return .cancelled }
            attempt.countsTowardBreaker = (error as? any TTSAttemptError)?.countsTowardBreaker ?? true
            return .failed(error.localizedDescription)
        }
        guard gen == generation, !Task.isCancelled else { return .cancelled }
        return .finished
    }

    /// Waits for the attempt's audio to play out, then names the outcome (REQ-T-13/16/21).
    func conclude(
        _ end: AttemptEnd, record: AttemptRecord, engine: TTSEngine, utterance: Utterance, gen: UInt64
    ) async -> Outcome {
        if end == .cancelled { return .stale }
        if end == .outputFailed {
            output.stop()
            return .skipped(.outputUnavailable)
        }
        switch await drainPlayback(record) {
        case .stopped:
            return gen == generation ? .skipped(.outputUnavailable) : .stale
        case .stalled:
            output.stop()
            return .skipped(.outputUnavailable)
        case .played:
            if end == .timedOut { return .skipped(.timeout) }
            guard end == .finished else { return .skipped(.interrupted) }
            await recordMetrics(record, engine: engine, utterance: utterance)
            return .played
        }
    }

    /// Waits for the attempt's last buffer to be played back, bounded by the audio's length plus
    /// `playbackGrace`, so a device that never reports back cannot keep `isSpeaking` true (REQ-T-16).
    private func drainPlayback(_ record: AttemptRecord) async -> Drain {
        guard let handle = record.lastHandle else { return .played }
        let bound = Duration.seconds(record.audioSeconds) + limits.playbackGrace
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

    private func recordMetrics(_ record: AttemptRecord, engine: TTSEngine, utterance: Utterance) async {
        guard let firstBufferAt = record.firstBufferAt else { return }   // nothing was heard
        let latency = record.startedAt.duration(to: firstBufferAt)
        await metrics.record(TTSMetrics(
            engine: engine,
            synthesisLatencyMs: Int(latency / .milliseconds(1)),
            textLength: utterance.text.count,
            locale: utterance.locale,
            timestamp: Date()
        ))
    }
}
