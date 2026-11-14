import Foundation
import OSLog

// MARK: - Model

/// What `PipelineTracer` holds about the utterances in flight, and its matching rules
/// (M9 design §2.1; clause split design §7, P-5).
nonisolated extension PipelineTracer {
    struct Utterance {
        let seq: Int
        let capturedAt: Date
        /// The VAD's segment id (0: untagged). Tentatives of one utterance share `capturedAt`, never the id.
        let segmentID: UInt64
        var sttText: String?
        /// The STT text's two clauses, once a translation or failure of one of them matched (P-5).
        /// Empty: the sentence is translated whole.
        var sttParts: [String] = []
        /// Translations by part: one (whole) or two (split, nil until that part is translated).
        var translations: [String?] = []
        /// The second part will not be heard (its translation or its synthesis failed).
        var partOneFailed = false
        /// Parts handed to TTS, and parts whose first buffer was scheduled (both in part order).
        var spokenParts = 0
        var heardParts = 0
        /// When part 0's synthesis ended with audio while part 1 was still due.
        var firstPartEnd: ContinuousClock.Instant?
        var interval: OSSignpostIntervalState?

        var isSplit: Bool { !sttParts.isEmpty }
        /// The parts the utterance waits for before `ttsEnd`.
        var expectedParts: Int { isSplit && !partOneFailed ? 2 : 1 }
        var isTranslatedWhole: Bool { !isSplit && !translations.isEmpty }

        func translation(ofPart part: Int) -> String? { part < translations.count ? translations[part] : nil }
    }

    /// One unit handed to TTS: a whole utterance (part 0) or one part of a split one.
    struct SpokenItem: Equatable {
        let seq: Int
        let part: Int
    }

    /// A synthesis attempt: the items it carries, its text (a fallback retries the same text), when
    /// its synthesizer started and whether it already finished (buffers may still be scheduled after).
    struct Attempt {
        var items: [SpokenItem]
        let text: String
        var engine: String
        var startedAt: ContinuousClock.Instant
        var finished = false
    }

    /// A terminal event decided under the lock and emitted after it.
    struct Ending {
        let seq: Int
        let stage: TraceStage
        let stamp: ContinuousClock.Instant
        var detail: [String: String] = [:]
    }

    /// A non-terminal event decided under the lock and emitted after it.
    struct Stamp {
        let stage: TraceStage
        let detail: [String: String]
    }

    /// What one `bufferScheduled` call decided: first-heard items, endings, engine and handoff gap,
    /// and whether the attempt started while the audio before it was still playing (`overlapped`).
    struct BufferOutcome {
        var fresh: [SpokenItem] = []
        var endings: [Ending] = []
        var engine = ""
        var gap: Duration?
        var overlapped = false
    }

    /// A translated or failed source: utterance index, and its part (nil: the whole sentence).
    struct SourceMatch {
        let index: Int
        let part: Int?
    }

    struct State {
        var open: [Utterance] = []
        var nextSeq = 0
        var attempt: Attempt?
        /// Items handed to TTS and not taken by a synthesis attempt yet, in speak order.
        var waiting: [SpokenItem] = []
        /// The handoff gap reported for the next scheduled buffer (REQ-CS-56); dropped on stop.
        var handoffGap: Duration?
        /// Boundaries that arrived before their segment (separate streams): by segment id.
        var earlyBoundaries: [UInt64: SegmentBoundary] = [:]
        /// The id of the last segment closed. A VAD's ids only grow, so a boundary at or below it with no
        /// open utterance belongs to a segment that already ended and is not kept (G3 M1). The latest id,
        /// not the max: a VAD rebuilt under this tracer starts again from 1.
        var lastSegmentID: UInt64 = 0

        func index(of seq: Int) -> Int? { open.firstIndex { $0.seq == seq } }

        func isHeard(_ item: SpokenItem) -> Bool {
            open.contains { $0.seq == item.seq && item.part < $0.heardParts }
        }

        func translation(of item: SpokenItem) -> String? {
            index(of: item.seq).flatMap { open[$0].translation(ofPart: item.part) }
        }

        /// The utterance a translated (or failed) `source` belongs to: the oldest whose whole STT text it
        /// is, else the oldest with a clause it is that is still untranslated (P-5). The clauses are
        /// those `ClauseSplitter` gives the STT text, as the coordinator splits it; a first part match
        /// marks the utterance split.
        mutating func match(source: String) -> SourceMatch? {
            if let index = open.firstIndex(where: { $0.sttText == source && $0.translations.isEmpty }) {
                return SourceMatch(index: index, part: nil)
            }
            for index in open.indices {
                guard let text = open[index].sttText, !text.isEmpty, !open[index].isTranslatedWhole else { continue }
                let utterance = open[index]
                let parts = utterance.isSplit ? utterance.sttParts : ClauseSplitter.split(text)
                guard parts.count == 2, let part = parts.indices.first(where: {
                    parts[$0] == source && utterance.translation(ofPart: $0) == nil
                        && !($0 == 1 && utterance.partOneFailed)
                }) else { continue }
                if !utterance.isSplit {
                    open[index].sttParts = parts
                    open[index].translations = [nil, nil]
                }
                return SourceMatch(index: index, part: part)
            }
            return nil
        }

        /// The waiting items a synthesis of `text` carries: the first run whose translations, joined by a
        /// space, make `text` (one item, or several that `TTSPlaybackService` merged), searched from the
        /// oldest; an unexpected text takes the oldest item only. A part's attempt so never takes a
        /// later sentence spoken before it (design §7).
        func take(_ text: String) -> [SpokenItem] {
            for start in waiting.indices {
                var joined = ""
                for end in start..<waiting.count {
                    let piece = translation(of: waiting[end]) ?? ""
                    joined = joined.isEmpty ? piece : joined + " " + piece
                    if joined == text { return Array(waiting[start...end]) }
                    if joined.count >= text.count { break }
                }
            }
            return Array(waiting.prefix(1))
        }

        /// The attempt carrying `items` ended with all their audio scheduled: the last part of each
        /// utterance ends it (`ttsEnd`); part 0 of a sentence still waiting for part 1 keeps it open.
        mutating func conclude(_ items: [SpokenItem], at stamp: ContinuousClock.Instant) -> [Ending] {
            items.compactMap { item in
                guard let index = index(of: item.seq) else { return nil }
                guard item.part + 1 >= open[index].expectedParts else {
                    open[index].firstPartEnd = stamp
                    return nil
                }
                return Ending(seq: item.seq, stage: .ttsEnd, stamp: stamp, detail: partsSpoken(open[index]))
            }
        }

        /// Items of an attempt that produced no audio: a sentence never heard is dropped; a second part
        /// ends its sentence at part 0's end (`partsSpoken: "1"`).
        mutating func silenced(_ items: [SpokenItem], at stamp: ContinuousClock.Instant) -> [Ending] {
            var seen: Set<Int> = []
            return items.compactMap { item in
                guard seen.insert(item.seq).inserted, let index = index(of: item.seq) else { return nil }
                guard open[index].heardParts > 0 else {
                    return Ending(seq: item.seq, stage: .dropped, stamp: stamp, detail: ["reason": "tts-no-audio"])
                }
                return partOneFailed(at: index)
            }
        }

        /// Part 1 of the utterance at `index` will not be heard: it ends at part 0's end if that is past.
        mutating func partOneFailed(at index: Int) -> Ending? {
            open[index].partOneFailed = true
            guard let end = open[index].firstPartEnd else { return nil }
            return Ending(seq: open[index].seq, stage: .ttsEnd, stamp: end, detail: partsSpoken(open[index]))
        }

        private func partsSpoken(_ utterance: Utterance) -> [String: String] {
            utterance.isSplit && utterance.partOneFailed ? ["partsSpoken": "1"] : [:]
        }
    }
}
