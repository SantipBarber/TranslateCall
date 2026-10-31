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

/// Trailing zeros added to a tentative's STT copy so it carries a final's silence (G3 I1).
struct TentativePaddingTests {

    @Test func roundsUpToWholeSteps() {
        #expect(TentativePadding.roundedUp(9_600, step: 1_600) == 9_600)
        #expect(TentativePadding.roundedUp(9_601, step: 1_600) == 11_200)
        #expect(TentativePadding.roundedUp(5_504, step: 4_096) == 8_192)
        #expect(TentativePadding.roundedUp(0, step: 4_096) == 0)
        #expect(TentativePadding.roundedUp(100, step: 0) == 100)
    }

    @Test func padsUpToTheFinalSilence() {
        let utterance = [Float](repeating: 0.5, count: 10)
        let padded = TentativePadding.padded(utterance, silenceInBuffer: 2, finalSilence: 6)
        #expect(padded.count == 14)
        #expect(Array(padded.prefix(10)) == utterance, "the real audio is untouched")
        #expect(padded.suffix(4).allSatisfy { $0 == 0 })
    }

    @Test func neverTrims() {
        let utterance = [Float](repeating: 0.5, count: 10)
        #expect(TentativePadding.padded(utterance, silenceInBuffer: 6, finalSilence: 2) == utterance)
    }

    /// Silero's final carries the first silent chunk plus whole chunks up to FluidAudio's pause
    /// (`minSilenceDuration` − one chunk): 3 chunks (0.768 s) at the 0.6 s default. The tentative holds
    /// the first silent chunk, so it gets the other two.
    @Test func sileroPaddingMatchesTodaysFinal() {
        #expect(SileroVADService.tentativePaddingSamples(for: .default) == 2 * 4_096)
        var oneChunkPause = VADConfiguration()
        oneChunkPause.minSilenceDuration = 0.256
        #expect(SileroVADService.tentativePaddingSamples(for: oneChunkPause) == 0)
    }
}
