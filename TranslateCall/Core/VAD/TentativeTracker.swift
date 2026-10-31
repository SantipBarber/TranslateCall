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

    /// Opens a tentative and returns its id; nil when one is already open.
    mutating func silenceStarted() -> UInt64? {
        guard openID == nil else { return nil }
        lastID += 1
        openID = lastID
        return lastID
    }

    /// Speech resumed before the pause completed: retracts the open tentative, if any.
    mutating func speechResumed() -> SegmentBoundary? {
        close().map(SegmentBoundary.retract)
    }

    /// The pause completed: commits the open tentative, if any (no new segment is needed).
    mutating func ended() -> SegmentBoundary? {
        close().map(SegmentBoundary.commit)
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
        defer { openID = nil }
        return openID
    }
}
