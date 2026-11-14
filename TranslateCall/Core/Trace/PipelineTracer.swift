import Foundation
import OSLog
import Synchronization

/// Follows each utterance of one direction through VAD → STT → translation → TTS and stamps it
/// (M9 REQ-BH-10…13, design §2.1). Each stage is FIFO per direction, so stages are matched by order
/// and content, never by an id threaded through the stage protocols:
/// - an STT result belongs to the segment with the same `capturedAt`; older segments without a
///   result were dropped by STT;
/// - a translation and a `speak` belong to the oldest utterance whose text they carry; a split
///   sentence's parts (clause split, P-5) are matched against the clauses of its STT text;
/// - a synthesis attempt carries the joined texts of the items (whole sentences or parts)
///   `TTSPlaybackService` merged.
///
/// Synchronous and lock-based: callers never await, and the order of calls is the order of events.
/// Only utterances still in flight are kept (ended ones are forgotten), so memory stays bounded.
nonisolated final class PipelineTracer: Sendable {
    let direction: TraceDirection
    private let sink: any TraceSink
    private let trailingSilence: Duration
    let now: @Sendable () -> ContinuousClock.Instant
    /// `Date` ↔ monotonic clock, fixed once so `capturedAt` maps onto the clock every other stamp uses.
    private let originDate: Date
    private let originInstant: ContinuousClock.Instant
    let state = Mutex(State())
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
    /// `id` is the segment's id (0: untagged); a boundary seen earlier for it is applied now.
    func segmentClosed(capturedAt: Date, audioSeconds: Double, id: UInt64 = 0) {
        let stamp = now()
        let start = originInstant + .seconds(capturedAt.timeIntervalSince(originDate))
        let interval = signposter.beginInterval("Utterance")
        let (seq, early) = state.withLock { current -> (Int, SegmentBoundary?) in
            defer { current.nextSeq += 1 }
            current.open.append(Utterance(seq: current.nextSeq, capturedAt: capturedAt, segmentID: id,
                                          interval: interval))
            if id != 0 { current.lastSegmentID = id }
            return (current.nextSeq, id == 0 ? nil : current.earlyBoundaries.removeValue(forKey: id))
        }
        emit(seq, .speechStart, at: start)
        emit(seq, .vadEnd, at: stamp, ["segmentAudioMs": Self.ms(.seconds(audioSeconds)),
                                    "trailingSilenceMs": Self.ms(trailingSilence)])
        switch early {
        case .commit: emit(seq, .committed, at: stamp)
        case .retract: finish(seq, .retracted, at: stamp)
        case nil: break
        }
    }

    /// The tentative segment `id` was confirmed: stamps its utterance (or waits for the segment).
    func segmentCommitted(id: UInt64) { boundary(.commit(id)) }

    /// The tentative segment `id` was withdrawn: its utterance ends as `retracted` and is forgotten (or
    /// waits for the segment). Later tentatives of the same utterance open their own, keyed by their id.
    func segmentRetracted(id: UInt64) { boundary(.retract(id)) }

    private func boundary(_ boundary: SegmentBoundary) {
        let stamp = now()
        let id: UInt64
        switch boundary {
        case .commit(let value), .retract(let value): id = value
        }
        guard id != 0 else { return }
        let seq = state.withLock { current -> Int? in
            if let seq = current.open.first(where: { $0.segmentID == id })?.seq { return seq }
            if id > current.lastSegmentID { current.earlyBoundaries[id] = boundary }   // else: already ended
            return nil
        }
        guard let seq else { return }
        switch boundary {
        case .commit: emit(seq, .committed, at: stamp)
        case .retract: finish(seq, .retracted, at: stamp)
        }
    }

    /// STT finished the segment `segmentID` (0: untagged, matched by `capturedAt`). A result whose
    /// segment is not open (retracted) is ignored. Older segments still waiting were dropped by STT
    /// (empty or below the confidence floor). An empty text ends the utterance.
    /// `dropped`: what the engine recognized before dropping it for low confidence (QS-8).
    func transcribed(
        capturedAt: Date, text: String, engine: String, confidence: Float, segmentID: UInt64 = 0,
        dropped: DroppedTranscript? = nil
    ) {
        let stamp = now()
        let (skipped, seq) = state.withLock { current -> ([Int], Int?) in
            guard let index = current.open.firstIndex(where: {
                $0.sttText == nil && (segmentID == 0 ? $0.capturedAt == capturedAt : $0.segmentID == segmentID)
            }) else { return ([], nil) }
            current.open[index].sttText = text
            let skipped = current.open[..<index].filter { $0.sttText == nil }.map(\.seq)
            return (skipped, current.open[index].seq)
        }
        skipped.forEach { finish($0, .dropped, at: stamp, ["reason": "stt-empty"]) }
        guard let seq else { return }
        emit(seq, .sttFinal, at: stamp, ["text": text, "engine": engine, "confidence": String(confidence)])
        guard text.isEmpty else { return }
        if let dropped {
            finish(seq, .dropped, at: stamp, [
                "reason": "low-confidence", "droppedText": dropped.text,
                "droppedConfidence": String(dropped.confidence)
            ])
        } else {
            finish(seq, .dropped, at: stamp, ["reason": "empty-text"])
        }
    }

    /// A translation finished: of a whole sentence (`translated`), or of one clause of a split one
    /// (P-5). Part 0 is `translated` (`parts: "2"`, REQ-CS-30); once both are in, `translatedAll`
    /// carries the joined text (REQ-CS-31).
    func translated(source: String, result: String) {
        let stamp = now()
        let stamped = state.withLock { current -> (seq: Int, stamps: [Stamp])? in
            guard let match = current.match(source: source) else { return nil }
            let seq = current.open[match.index].seq
            guard let part = match.part else {
                current.open[match.index].translations = [result]
                return (seq, [Stamp(stage: .translated, detail: ["text": result])])
            }
            current.open[match.index].translations[part] = result
            let utterance = current.open[match.index]
            guard let first = utterance.translation(ofPart: 0) else { return (seq, []) }   // part 1 came first
            var stamps: [Stamp] = []
            if part == 0 { stamps.append(Stamp(stage: .translated, detail: ["text": first, "parts": "2"])) }
            if let second = utterance.translation(ofPart: 1) {
                stamps.append(Stamp(stage: .translatedAll, detail: ["text": first + " " + second]))
            }
            return (seq, stamps)
        }
        guard let stamped else { return }
        stamped.stamps.forEach { emit(stamped.seq, $0.stage, at: stamp, $0.detail) }
    }

    /// A whole sentence or its part 0 failed: `dropped`. Its part 1 failed: the sentence ends at
    /// part 0's synthesis end with `partsSpoken: "1"` (now, or when that synthesis ends).
    func translationFailed(source: String, error: Error) {
        let stamp = now()
        let ending = state.withLock { current -> Ending? in
            guard let match = current.match(source: source) else { return nil }
            guard match.part == 1 else {
                return Ending(seq: current.open[match.index].seq, stage: .dropped, stamp: stamp,
                              detail: ["reason": "translate-\(String(describing: error))"])
            }
            return current.partOneFailed(at: match.index)
        }
        if let ending { finish(ending) }
    }

    /// The playback service will schedule the first buffer of an attempt `gap` after the audio
    /// scheduled before it ends (REQ-CS-56): kept for the next `bufferScheduled`.
    func handoff(gap: Duration) {
        state.withLock { $0.handoffGap = gap }
    }

    /// The output was stopped: a held handoff gap belongs to no buffer any more.
    func outputStopped() {
        state.withLock { $0.handoffGap = nil }
    }

    /// Ends every open utterance as dropped (session stop, bench idle timeout); a split sentence whose
    /// part 0 was heard ends `ttsEnd` at part 0's end with `partsSpoken: "1"` and the `reason`.
    func closeOpen(reason: String) {
        let stamp = now()
        let closed = state.withLock { current -> [Utterance] in
            current.attempt = nil
            current.waiting.removeAll()
            current.handoffGap = nil
            current.earlyBoundaries.removeAll()
            defer { current.open.removeAll() }
            return current.open
        }
        for utterance in closed {
            if let interval = utterance.interval { signposter.endInterval("Utterance", interval) }
            // A split sentence whose part 0 was heard ends there: it was spoken, not dropped (P-6).
            if let end = utterance.firstPartEnd {
                emit(utterance.seq, .ttsEnd, at: end, ["partsSpoken": "1", "reason": reason])
            } else {
                emit(utterance.seq, .dropped, at: stamp, ["reason": reason])
            }
        }
    }

    // MARK: - Emission

    /// Forgets `seq`, closes its signpost interval and emits its last event, unless another call
    /// already ended it (one terminal event per utterance).
    func finish(_ seq: Int, _ stage: TraceStage, at stamp: ContinuousClock.Instant,
                _ detail: [String: String] = [:]) {
        let removed = state.withLock { current -> Utterance? in
            guard let index = current.index(of: seq) else { return nil }
            current.waiting.removeAll { $0.seq == seq }
            return current.open.remove(at: index)
        }
        guard let removed else { return }
        if let interval = removed.interval { signposter.endInterval("Utterance", interval) }
        emit(seq, stage, at: stamp, detail)
    }

    func finish(_ ending: Ending) { finish(ending.seq, ending.stage, at: ending.stamp, ending.detail) }

    func emit(_ seq: Int, _ stage: TraceStage, at stamp: ContinuousClock.Instant,
              _ detail: [String: String] = [:]) {
        signposter.emitEvent("Stage",
                             "\(self.direction.rawValue, privacy: .public) \(seq) \(stage.rawValue, privacy: .public)")
        sink.record(TraceEvent(direction: direction, seq: seq, stage: stage, time: stamp, detail: detail))
    }

    static func ms(_ duration: Duration) -> String {
        String(Int((Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15).rounded()))
    }
}
