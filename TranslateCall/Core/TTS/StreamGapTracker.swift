import Foundation

// MARK: - StreamGapTracker

/// Counts the audible gaps of a streamed utterance (qwen-streaming design §5, REQ-QS-22).
///
/// With the first chunk's arrival as the start, `playEnd` is when the audio received so far would finish
/// if played back to back. A chunk arriving after `playEnd` is a gap of `arrival − playEnd`, and playback
/// restarts from that chunk; otherwise the chunk queues behind the audio already received. It ignores
/// the output's own scheduling latency, so it slightly under-counts.
nonisolated struct StreamGapTracker: Sendable {
    private(set) var gapCount = 0
    private(set) var gapSeconds: Double = 0
    /// Arrival of the first chunk, measured from the start of the attempt.
    private(set) var firstChunkAt: Duration?
    private var playEnd: Double = 0

    /// Records a chunk of `seconds` of audio that arrived `arrivedAt` after the attempt started.
    mutating func chunk(arrivedAt: Duration, seconds: Double) {
        let arrival = arrivedAt.secondsValue
        guard firstChunkAt != nil else {
            firstChunkAt = arrivedAt
            playEnd = arrival + seconds
            return
        }
        if arrival > playEnd {
            gapCount += 1
            gapSeconds += arrival - playEnd
            playEnd = arrival + seconds
        } else {
            playEnd += seconds
        }
    }
}

extension Duration {
    /// The duration in seconds, as a `Double`.
    nonisolated var secondsValue: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
