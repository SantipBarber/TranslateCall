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
        attempt = AttemptRecord(startedAt: now(), epoch: outputEpoch)
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
                guard schedule(buffer) else { return .outputFailed }
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

    /// Schedules one buffer of the attempt in flight; false when the output was stopped under the
    /// attempt (REQ-CS-54) or refused the buffer. Reports the handoff gap before the attempt's first
    /// buffer when audio was scheduled before it in this generation (REQ-CS-56).
    private func schedule(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard attempt.epoch == outputEpoch else { return false }
        if attempt.bufferCount == 0, let end = scheduledAudioEnd {
            (output as? any HandoffReporting)?.handoff(gap: max(.zero, end.duration(to: now())))
        }
        do {
            attempt.lastHandle = try output.schedule(buffer)
        } catch {
            logger.error("TTS output refused a buffer: \(error.localizedDescription, privacy: .public)")
            failOutput()
            return false
        }
        let current = now()
        scheduledAudioEnd = max(current, scheduledAudioEnd ?? current) + Self.length(of: buffer)
        return true
    }

    /// Exact for integer sample rates, so the audio timeline does not drift by rounding.
    private static func length(of buffer: AVAudioPCMBuffer) -> Duration {
        let rate = buffer.format.sampleRate
        guard rate > 0 else { return .zero }
        guard rate == rate.rounded() else { return .seconds(Double(buffer.frameLength) / rate) }
        return .seconds(Int64(buffer.frameLength)) / Int64(rate)
    }

    /// Stops the output on a failure or stall: everything scheduled is lost, including the audio of
    /// an utterance synthesized ahead, which the epoch bump tells (REQ-CS-54).
    func failOutput() {
        output.stop()
        outputEpoch &+= 1
        scheduledAudioEnd = nil
    }

    /// Waits for the attempt's audio to play out, then names the outcome (REQ-T-13/16/21).
    func conclude(
        _ end: AttemptEnd, record: AttemptRecord, engine: TTSEngine, utterance: Utterance, gen: UInt64
    ) async -> Outcome {
        guard end != .cancelled, gen == generation else { return .stale }
        // The output refused this attempt's audio, or was stopped under it while the utterance
        // before it played (both already stopped the output).
        guard end != .outputFailed, record.epoch == outputEpoch else { return .skipped(.outputUnavailable) }
        switch await drainPlayback(record) {
        case .stopped, .stalled:
            guard gen == generation else { return .stale }
            // Lost or stalled under this utterance: the one ahead, if any, went with it.
            if record.epoch == outputEpoch { failOutput() }
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
