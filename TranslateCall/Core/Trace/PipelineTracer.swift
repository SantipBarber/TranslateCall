import Foundation
import OSLog
import Synchronization

/// Follows each utterance of one direction through VAD → STT → translation → TTS and stamps it
/// (M9 REQ-BH-10…13, design §2.1). Each stage is FIFO per direction, so stages are matched by order
/// and content, never by an id threaded through the stage protocols:
/// - an STT result belongs to the segment with the same `capturedAt`; older segments without a
///   result were dropped by STT;
/// - a translation and a `speak` belong to the oldest utterance whose text they carry;
/// - a synthesis attempt carries the joined texts of the utterances `TTSPlaybackService` merged.
///
/// Synchronous and lock-based: callers never await, and the order of calls is the order of events.
/// Only utterances still in flight are kept (ended ones are forgotten), so memory stays bounded.
nonisolated final class PipelineTracer: Sendable {
    private struct Utterance {
        let seq: Int
        let capturedAt: Date
        var sttText: String?
        var translation: String?
        var spoken = false
        var attempted = false
        var heard = false
        var interval: OSSignpostIntervalState?
    }

    /// A synthesis attempt: the utterances it carries, its text (a fallback retries the same text) and
    /// whether its synthesizer already finished (buffers may still be scheduled after that).
    private struct Attempt {
        var seqs: [Int]
        let text: String
        var engine: String
        var finished = false
    }

    /// What one `bufferScheduled` call decided: first-heard seqs, seqs that end now, and the engine.
    private struct BufferOutcome {
        var fresh: [Int] = []
        var done: [Int] = []
        var engine = ""
    }

    private struct State {
        var open: [Utterance] = []
        var nextSeq = 0
        var attempt: Attempt?

        func isHeard(_ seq: Int) -> Bool { open.contains { $0.seq == seq && $0.heard } }
    }

    let direction: TraceDirection
    private let sink: any TraceSink
    private let trailingSilence: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    /// `Date` ↔ monotonic clock, fixed once so `capturedAt` maps onto the clock every other stamp uses.
    private let originDate: Date
    private let originInstant: ContinuousClock.Instant
    private let state = Mutex(State())
    private let signposter = OSSignposter(subsystem: "com.spbarber.TranslateCall", category: "PipelineTrace")

    /// - Parameter trailingSilence: the VAD's closing pause (`VADConfiguration.minSilenceDuration`);
    ///   lets a sink estimate the end of speech as `vadEnd − trailingSilence` (design §2.3).
    init(direction: TraceDirection, sink: any TraceSink, trailingSilence: Duration,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, originDate: Date = Date()) {
        self.direction = direction
        self.sink = sink
        self.trailingSilence = trailingSilence
        self.now = now
        self.originDate = originDate
        originInstant = now()
    }

    /// Seqs that have not reached `ttsEnd` or `dropped` yet.
    var openSeqs: [Int] { state.withLock { $0.open.map(\.seq) } }

    // MARK: - Stages

    /// The VAD closed a segment: `speechStart` (from the segment's start date) and `vadEnd` (now).
    func segmentClosed(capturedAt: Date, audioSeconds: Double) {
        let stamp = now()
        let start = originInstant + .seconds(capturedAt.timeIntervalSince(originDate))
        let interval = signposter.beginInterval("Utterance")
        let seq = state.withLock { current in
            defer { current.nextSeq += 1 }
            current.open.append(Utterance(seq: current.nextSeq, capturedAt: capturedAt, interval: interval))
            return current.nextSeq
        }
        emit(seq, .speechStart, at: start)
        emit(seq, .vadEnd, at: stamp, ["segmentAudioMs": Self.ms(.seconds(audioSeconds)),
                                    "trailingSilenceMs": Self.ms(trailingSilence)])
    }

    /// STT finished the segment that started at `capturedAt`. Older segments still waiting were
    /// dropped by STT (empty or below the confidence floor). An empty text ends the utterance.
    func transcribed(capturedAt: Date, text: String, engine: String, confidence: Float) {
        let stamp = now()
        let (skipped, seq) = state.withLock { current -> ([Int], Int?) in
            guard let index = current.open.firstIndex(where: { $0.capturedAt == capturedAt && $0.sttText == nil })
            else { return ([], nil) }
            current.open[index].sttText = text
            let skipped = current.open[..<index].filter { $0.sttText == nil }.map(\.seq)
            return (skipped, current.open[index].seq)
        }
        skipped.forEach { finish($0, .dropped, at: stamp, ["reason": "stt-empty"]) }
        guard let seq else { return }
        emit(seq, .sttFinal, at: stamp, ["text": text, "engine": engine, "confidence": String(confidence)])
        if text.isEmpty { finish(seq, .dropped, at: stamp, ["reason": "empty-text"]) }
    }

    func translated(source: String, result: String) {
        let stamp = now()
        let seq = state.withLock { current -> Int? in
            guard let index = current.open.firstIndex(where: { $0.sttText == source && $0.translation == nil })
            else { return nil }
            current.open[index].translation = result
            return current.open[index].seq
        }
        if let seq { emit(seq, .translated, at: stamp, ["text": result]) }
    }

    func translationFailed(source: String, error: Error) {
        let stamp = now()
        let seq = state.withLock { current in
            current.open.first { $0.sttText == source && $0.translation == nil }?.seq
        }
        if let seq { finish(seq, .dropped, at: stamp, ["reason": "translate-\(String(describing: error))"]) }
    }

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

    /// Ends every open utterance as dropped (session stop, bench idle timeout).
    func closeOpen(reason: String) {
        let stamp = now()
        let closed = state.withLock { current -> [Utterance] in
            current.attempt = nil
            defer { current.open.removeAll() }
            return current.open
        }
        for utterance in closed {
            if let interval = utterance.interval { signposter.endInterval("Utterance", interval) }
            emit(utterance.seq, .dropped, at: stamp, ["reason": reason])
        }
    }

    // MARK: - Emission

    /// Forgets `seq`, closes its signpost interval and emits its last event, unless another call
    /// already ended it (one terminal event per utterance).
    private func finish(_ seq: Int, _ stage: TraceStage, at stamp: ContinuousClock.Instant,
                        _ detail: [String: String] = [:]) {
        let removed = state.withLock { current -> Utterance? in
            guard let index = current.open.firstIndex(where: { $0.seq == seq }) else { return nil }
            return current.open.remove(at: index)
        }
        guard let removed else { return }
        if let interval = removed.interval { signposter.endInterval("Utterance", interval) }
        emit(seq, stage, at: stamp, detail)
    }

    private func emit(_ seq: Int, _ stage: TraceStage, at stamp: ContinuousClock.Instant,
                      _ detail: [String: String] = [:]) {
        signposter.emitEvent("Stage",
                             "\(self.direction.rawValue, privacy: .public) \(seq) \(stage.rawValue, privacy: .public)")
        sink.record(TraceEvent(direction: direction, seq: seq, stage: stage, time: stamp, detail: detail))
    }

    private static func ms(_ duration: Duration) -> String {
        String(Int((Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15).rounded()))
    }
}
