import Foundation
import Synchronization

// MARK: - TTS stages

/// The speak → synthesis → buffer stages of `PipelineTracer` (M9 design §2.1).
nonisolated extension PipelineTracer {
    /// The coordinator handed `text` to TTS.
    func speakRequested(text: String) {
        state.withLock { current in
            guard let index = current.open.firstIndex(where: { !$0.spoken && $0.translation == text }) else { return }
            current.open[index].spoken = true
        }
    }

    /// A synthesizer (`engine`) started on `text`: the oldest spoken utterances whose texts, joined by a space,
    /// make `text` (one, or several that TTSPlaybackService merged). The same text again before any
    /// audio is the fallback engine retrying: the attempt is kept. A previous attempt that produced
    /// no audio is dropped.
    func synthesisStarted(text: String, engine: String) {
        let stamp = now()
        let silent = state.withLock { current -> [Int] in
            var silent: [Int] = []
            if var attempt = current.attempt {
                let unheard = attempt.seqs.filter { !current.isHeard($0) }
                if attempt.text == text, unheard.count == attempt.seqs.count {
                    attempt.finished = false
                    attempt.engine = engine   // the fallback engine is the one that will be heard
                    current.attempt = attempt
                    return []
                }
                silent = unheard
            }
            let waiting = current.open.indices.filter { current.open[$0].spoken && !current.open[$0].attempted }
            var taken: [Int] = []
            var joined = ""
            for index in waiting {
                let part = current.open[index].translation ?? ""
                joined = joined.isEmpty ? part : joined + " " + part
                taken.append(index)
                if joined == text { break }
            }
            if joined != text { taken = Array(waiting.prefix(1)) }   // unexpected text: the oldest only
            taken.forEach { current.open[$0].attempted = true }
            current.attempt = Attempt(seqs: taken.map { current.open[$0].seq }, text: text, engine: engine)
            return silent
        }
        silent.forEach { finish($0, .dropped, at: stamp, ["reason": "tts-no-audio"]) }
    }

    /// The playback service scheduled a buffer on the output: the attempt's first buffer is
    /// `ttsFirstBuffer` for each utterance it carries.
    func bufferScheduled() {
        let stamp = now()
        let outcome = state.withLock { current -> BufferOutcome in
            guard let attempt = current.attempt else { return BufferOutcome() }
            var fresh: [Int] = []
            for seq in attempt.seqs {
                guard let index = current.open.firstIndex(where: { $0.seq == seq }), !current.open[index].heard
                else { continue }
                current.open[index].heard = true
                fresh.append(seq)
            }
            guard attempt.finished else { return BufferOutcome(fresh: fresh, engine: attempt.engine) }
            current.attempt = nil
            return BufferOutcome(fresh: fresh, done: attempt.seqs, engine: attempt.engine)
        }
        var detail = ["engine": outcome.engine]
        if outcome.fresh.count > 1 { detail["mergedSeqs"] = outcome.fresh.map(String.init).joined(separator: ",") }
        outcome.fresh.forEach { emit($0, .ttsFirstBuffer, at: stamp, detail) }
        outcome.done.forEach { finish($0, .ttsEnd, at: stamp) }
    }

    /// The attempt's synthesizer finished (its stream ended, normally or not). Its utterances end
    /// (`ttsEnd`) once their audio was scheduled; without audio they wait for a retry or `closeOpen`.
    func synthesisFinished() {
        let stamp = now()
        let done = state.withLock { current -> [Int] in
            guard var attempt = current.attempt else { return [] }
            guard attempt.seqs.allSatisfy(current.isHeard) else {
                attempt.finished = true
                current.attempt = attempt
                return []
            }
            current.attempt = nil
            return attempt.seqs
        }
        done.forEach { finish($0, .ttsEnd, at: stamp) }
    }
}
