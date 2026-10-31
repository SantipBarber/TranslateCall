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
}
