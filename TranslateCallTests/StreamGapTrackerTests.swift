import Testing
@testable import TranslateCall

@Suite("StreamGapTracker")
struct StreamGapTrackerTests {
    struct Case: Sendable, CustomTestStringConvertible {
        /// (arrival since the attempt started, chunk length), both in seconds.
        let chunks: [(Double, Double)]
        let gapCount: Int
        let gapSeconds: Double
        var testDescription: String { "\(chunks.map { "\($0.0)+\($0.1)" })" }
    }

    @Test("a chunk arriving after the audio so far would have finished is a gap (design §5)", arguments: [
        Case(chunks: [(0.8, 0.32), (1.0, 0.32), (1.3, 0.32)], gapCount: 0, gapSeconds: 0),
        Case(chunks: [(0.8, 0.32), (1.5, 0.32)], gapCount: 1, gapSeconds: 0.38),
        Case(chunks: [(0.8, 0.32), (1.5, 0.32), (1.7, 0.32)], gapCount: 1, gapSeconds: 0.38)
    ])
    func rule(_ testCase: Case) {
        var tracker = StreamGapTracker()
        for (arrival, length) in testCase.chunks {
            tracker.chunk(arrivedAt: .seconds(arrival), seconds: length)
        }
        #expect(tracker.gapCount == testCase.gapCount)
        #expect(abs(tracker.gapSeconds - testCase.gapSeconds) < 1e-9)
        #expect(tracker.firstChunkAt == .seconds(testCase.chunks[0].0))
    }

    @Test("no chunk: no first-chunk time and no gaps")
    func empty() {
        let tracker = StreamGapTracker()
        #expect(tracker.firstChunkAt == nil)
        #expect(tracker.gapCount == 0)
        #expect(tracker.gapSeconds == 0)
    }
}
