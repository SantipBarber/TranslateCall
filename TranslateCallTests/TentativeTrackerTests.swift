import Testing
@testable import TranslateCall

/// Tentative/commit/retract bookkeeping shared by both VADs (REQ-QS-40/43/44, plan P6).
struct TentativeTrackerTests {

    @Test func commitPath() {
        var tracker = TentativeTracker()
        #expect(tracker.silenceStarted() == 1)
        #expect(tracker.ended() == .commit(1))
        #expect(tracker.nextFinalID() == 2)
    }

    @Test func retractThenCommit() {
        var tracker = TentativeTracker()
        #expect(tracker.silenceStarted() == 1)
        #expect(tracker.speechResumed() == .retract(1))
        #expect(tracker.silenceStarted() == 2)
        #expect(tracker.ended() == .commit(2))
    }

    @Test func noOpenTentative() {
        var tracker = TentativeTracker()
        #expect(tracker.ended() == nil)
        #expect(tracker.speechResumed() == nil)
    }

    @Test func forcedRetracts() {
        var tracker = TentativeTracker()
        #expect(tracker.silenceStarted() == 1)
        #expect(tracker.forced() == .retract(1))
        #expect(tracker.nextFinalID() == 2)
    }

    @Test func secondSilenceStartWhileOpenIsIgnored() {
        var tracker = TentativeTracker()
        #expect(tracker.silenceStarted() == 1)
        #expect(tracker.silenceStarted() == nil)
        #expect(tracker.ended() == .commit(1))
        #expect(tracker.ended() == nil)
    }

    // MARK: - Silero hysteresis band (REQ-QS-42)

    @Test func bandChunkAfterTentativeRetractsAtEnd() {
        var tracker = TentativeTracker()
        #expect(tracker.silenceStarted() == 1)
        tracker.observe(probability: 0.75, negativeThreshold: 0.7)   // soft syllable: neither speech nor silence
        tracker.observe(probability: 0.1, negativeThreshold: 0.7)
        #expect(tracker.ended() == .retract(1), "the final must carry the extra audio")
        #expect(tracker.nextFinalID() == 2)
    }

    @Test func onlySilentChunksAfterTentativeCommit() {
        var tracker = TentativeTracker()
        #expect(tracker.silenceStarted() == 1)
        tracker.observe(probability: 0.69, negativeThreshold: 0.7)
        tracker.observe(probability: 0.1, negativeThreshold: 0.7)
        #expect(tracker.ended() == .commit(1))
    }

    @Test func bandMarkDoesNotOutliveItsTentative() {
        var tracker = TentativeTracker()
        tracker.observe(probability: 0.8, negativeThreshold: 0.7)    // no tentative open: ignored
        #expect(tracker.silenceStarted() == 1)
        tracker.observe(probability: 0.8, negativeThreshold: 0.7)
        #expect(tracker.speechResumed() == .retract(1))
        #expect(tracker.silenceStarted() == 2)
        #expect(tracker.ended() == .commit(2))
    }
}
