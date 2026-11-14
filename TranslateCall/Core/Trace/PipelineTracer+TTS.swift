import Foundation
import Synchronization

// MARK: - TTS stages

/// The speak → synthesis → buffer stages of `PipelineTracer` (M9 design §2.1). Their unit is a
/// spoken item: a whole sentence, or one part of a split one (clause split design §7).
nonisolated extension PipelineTracer {
    /// The coordinator handed `text` to TTS: the oldest utterance whose next part (or whole
    /// translation) it is.
    func speakRequested(text: String) {
        state.withLock { current in
            guard let index = current.open.firstIndex(where: {
                $0.spokenParts < $0.expectedParts && $0.translation(ofPart: $0.spokenParts) == text
            }) else { return }
            current.waiting.append(SpokenItem(seq: current.open[index].seq, part: current.open[index].spokenParts))
            current.open[index].spokenParts += 1
        }
    }

    /// A synthesizer (`engine`) started on `text`: the waiting items whose texts, joined by a space,
    /// make `text` (one, or several that TTSPlaybackService merged). The same text again before any
    /// audio is the fallback engine retrying: the attempt is kept. A previous attempt's items that
    /// produced no audio end (`dropped`, or a part 1 at its part 0's end).
    func synthesisStarted(text: String, engine: String) {
        let stamp = now()
        let endings = state.withLock { current -> [Ending] in
            var silent: [SpokenItem] = []
            if var attempt = current.attempt {
                let unheard = attempt.items.filter { !current.isHeard($0) }
                if attempt.text == text, unheard.count == attempt.items.count {
                    attempt.finished = false
                    attempt.engine = engine   // the fallback engine is the one that will be heard
                    current.attempt = attempt
                    return []
                }
                silent = unheard
            }
            let taken = current.take(text)
            current.waiting.removeAll { taken.contains($0) }
            current.attempt = Attempt(items: taken, text: text, engine: engine)
            return current.silenced(silent, at: stamp)
        }
        endings.forEach(finish)
    }

    /// The playback service scheduled a buffer on the output: the attempt's first buffer is
    /// `ttsFirstBuffer` for each sentence (or part 0) it carries and `ttsPartBuffer` for each part 1.
    /// A handoff gap reported before it goes on its first such event (REQ-CS-56).
    func bufferScheduled() {
        let stamp = now()
        let outcome = state.withLock { current -> BufferOutcome in
            let gap = current.handoffGap
            current.handoffGap = nil
            guard let attempt = current.attempt else { return BufferOutcome() }
            var outcome = BufferOutcome(engine: attempt.engine, gap: gap)
            for item in attempt.items {
                guard let index = current.index(of: item.seq), item.part >= current.open[index].heardParts
                else { continue }
                current.open[index].heardParts = item.part + 1
                outcome.fresh.append(item)
            }
            guard attempt.finished else { return outcome }
            current.attempt = nil
            outcome.endings = current.conclude(attempt.items, at: stamp)
            return outcome
        }
        emitFirstBuffers(outcome, at: stamp)
        outcome.endings.forEach(finish)
    }

    /// The attempt's synthesizer finished (its stream ended, normally or not). Its items end their
    /// sentences (`ttsEnd`) once their audio was scheduled; without audio they wait for a retry,
    /// the next attempt or `closeOpen`.
    func synthesisFinished() {
        let stamp = now()
        let endings = state.withLock { current -> [Ending] in
            guard var attempt = current.attempt else { return [] }
            guard attempt.items.allSatisfy(current.isHeard) else {
                attempt.finished = true
                current.attempt = attempt
                return []
            }
            current.attempt = nil
            return current.conclude(attempt.items, at: stamp)
        }
        endings.forEach(finish)
    }

    private func emitFirstBuffers(_ outcome: BufferOutcome, at stamp: ContinuousClock.Instant) {
        var seqs: [Int] = []
        for item in outcome.fresh where !seqs.contains(item.seq) { seqs.append(item.seq) }
        var shared = ["engine": outcome.engine]
        if seqs.count > 1 { shared["mergedSeqs"] = seqs.map(String.init).joined(separator: ",") }
        for (offset, item) in outcome.fresh.enumerated() {
            var detail = shared
            if offset == 0, let gap = outcome.gap { detail["handoffGapMs"] = Self.ms(gap) }
            if item.part == 0 {
                emit(item.seq, .ttsFirstBuffer, at: stamp, detail)
            } else {
                detail["part"] = String(item.part)
                emit(item.seq, .ttsPartBuffer, at: stamp, detail)
            }
        }
    }
}
