import Foundation

// MARK: - Segment protocol (FR-QS.5, design §10.2)

/// Whether a `SpeechSegment` closes its utterance or is an early look at it.
///
/// A `.tentative` segment is handed to STT at the first silence after speech; a later
/// `SegmentBoundary` with its id either commits it (the pause completed) or retracts it
/// (speech resumed: the next tentative covers the whole utterance from its start).
nonisolated enum SegmentKind: Sendable, Equatable {
    case tentative
    case final
}

/// The outcome of an open tentative segment, by segment id.
nonisolated enum SegmentBoundary: Sendable, Equatable {
    case commit(UInt64)
    case retract(UInt64)
}

// MARK: - TentativeTracker

/// Tentative/commit/retract bookkeeping shared by both VADs, free of audio so it is unit-tested
/// without CoreML. At most one tentative is open; ids increase across tentatives and finals.
nonisolated struct TentativeTracker: Sendable {
    private var lastID: UInt64 = 0
    private var openID: UInt64?
    /// Something since the tentative opened was not clear silence (Silero hysteresis band).
    private var heardSinceOpen = false

    /// Opens a tentative and returns its id; nil when one is already open.
    mutating func silenceStarted() -> UInt64? {
        guard openID == nil else { return nil }
        lastID += 1
        openID = lastID
        heardSinceOpen = false
        return lastID
    }

    /// Records a Silero chunk processed while a tentative is open. A probability at or above the
    /// negative threshold (FluidAudio's `threshold − 0.15`) neither retracts nor counts as silence,
    /// so it may be a soft syllable the tentative lacks: `ended()` then retracts instead of committing.
    mutating func observe(probability: Float, negativeThreshold: Float) {
        guard openID != nil, probability >= negativeThreshold else { return }
        heardSinceOpen = true
    }

    /// Speech resumed before the pause completed: retracts the open tentative, if any.
    mutating func speechResumed() -> SegmentBoundary? {
        close().map(SegmentBoundary.retract)
    }

    /// The pause completed: `.commit` for the open tentative (no new segment is needed), or
    /// `.retract` when `observe` saw possible speech after it (the caller then yields a `.final`
    /// with the whole utterance, REQ-QS-42); nil when none is open.
    mutating func ended() -> SegmentBoundary? {
        let heard = heardSinceOpen
        return close().map(heard ? SegmentBoundary.retract : SegmentBoundary.commit)
    }

    /// A force-emit or a flush replaces the open tentative with a final: retracts it, if any.
    mutating func forced() -> SegmentBoundary? {
        close().map(SegmentBoundary.retract)
    }

    /// The id for a `.final` segment.
    mutating func nextFinalID() -> UInt64 {
        lastID += 1
        return lastID
    }

    private mutating func close() -> UInt64? {
        defer { openID = nil; heardSinceOpen = false }
        return openID
    }
}

// MARK: - TentativePadding

/// Trailing digital silence for a `.tentative` (G3 I1). A tentative is cut at the first silence, so
/// it carries less trailing silence than the final it stands for; an engine may clip the last word or
/// drop below its confidence floor. The copy handed to STT gets zeros up to the silence that final
/// would have held. The VAD's own buffer is left as real audio, so a retract continues from it.
nonisolated enum TentativePadding {
    /// `samples` rounded up to a whole number of `step`s: a final ends on the first buffer or chunk
    /// that reaches the pause, so its trailing silence is the pause at that granularity.
    static func roundedUp(_ samples: Int, step: Int) -> Int {
        guard step > 0 else { return max(0, samples) }
        return (max(0, samples) + step - 1) / step * step
    }

    /// `utterance` followed by zeros so its trailing silence goes from `silenceInBuffer` to `finalSilence`.
    static func padded(_ utterance: [Float], silenceInBuffer: Int, finalSilence: Int) -> [Float] {
        let zeros = max(0, finalSilence - silenceInBuffer)
        guard zeros > 0 else { return utterance }
        return utterance + [Float](repeating: 0, count: zeros)
    }
}
